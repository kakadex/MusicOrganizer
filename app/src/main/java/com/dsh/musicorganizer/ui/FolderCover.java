package com.dsh.musicorganizer.ui;

import android.content.Context;

import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.VFile;

import java.io.File;
import java.io.FileInputStream;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 目录封面兜底（v0.1.54）。
 *
 * <p>很多中文曲库的音频本身**没有内嵌封面**，封面是同一文件夹里的一张图片
 * （{@code cover.jpg} / {@code folder.jpg} / {@code album.jpg} / 与文件夹同名的图片）。
 * 只读标签的话，这些歌永远是空占位 —— 明明文件夹里就有图。
 *
 * <p>思路：把目录当成封面的来源（同目录放一张图即可），
 * 每个目录只列一次目录（结果缓存），找不到就记成「没有」，不会反复列。
 */
final class FolderCover {

    /** 常见封面文件名（不含扩展名，小写比较）。 */
    private static final String[] STEMS = {
            "cover", "folder", "front", "album", "albumart", "artwork", "poster", "封面"
    };
    /** 只认图片扩展名；顺序即优先级（jpg 最常见，也最小）。 */
    private static final String[] EXTS = {".jpg", ".jpeg", ".png", ".webp"};
    /** 单张图最大读这么多字节，超过就当没有（防止一张巨图吃内存）。 */
    private static final int MAX_BYTES = 8 * 1024 * 1024;
    /** 目录缓存上限：一次最多记这么多目录，超了就清空重来。 */
    private static final int CACHE_LIMIT = 1000;

    /** 目录 docId → 封面文件（"" 表示这个目录确实没有，避免反复列目录）。 */
    // 并发访问：扫描线程（判定有无封面）与库页面补图线程都会读写，用并发 Map 防串数据。
    private static final Map<String, String[]> CACHE =
            new java.util.concurrent.ConcurrentHashMap<String, String[]>();

    private FolderCover() {
    }

    /** 目录内容变了（重扫 / 换目录）时调用：否则新放进来的 cover.jpg 要等重启才认。 */
    static void clear() {
        CACHE.clear();
    }

    /**
     * 找同目录的封面图并读出字节。
     *
     * @return 图片字节；没有返回 {@code null}
     */
    static byte[] read(Context ctx, Storage st, VFile audio) {
        if (st == null || audio == null) {
            return null;
        }
        final String parentId = audio.parentId;
        if (parentId == null || parentId.isEmpty()) {
            return null;
        }
        // 任何异常（provider 打不开图 / 列目录失败 / 超大图）都只当「这一首没有目录封面」，
        // 绝不能再把异常抛给调用方 —— 扫描阶段是按文件调用的，一首出错会拖垮整次扫描。
        try {
            String[] hit = CACHE.get(parentId);
            if (hit == null) {
                hit = find(st, parentId, audio);
                if (CACHE.size() > CACHE_LIMIT) {
                    CACHE.clear();
                }
                CACHE.put(parentId, hit == null ? new String[]{"", ""} : hit);
            }
            if (hit[0].isEmpty()) {
                return null;
            }
            return load(st, parentId, hit[0], hit[1]);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * 列一次目录，按优先级挑封面图。
     *
     * @return {docId, 文件名}；没有返回 null
     */
    private static String[] find(Storage st, String parentId, VFile audio) {
        List<VFile> kids;
        try {
            VFile dir = new VFile(parentId, null, "", "vnd.android.document/directory",
                    0L, 0L, true);
            kids = st.children(dir);
        } catch (Throwable t) {
            return null;
        }
        if (kids == null || kids.isEmpty()) {
            return null;
        }
        // 与文件夹同名的图片（例如「周杰伦/周杰伦.jpg」）优先级最高，其次 cover/folder…
        String folderName = folderStem(audio);
        String[] best = null;
        int bestRank = Integer.MAX_VALUE;
        for (VFile f : kids) {
            if (f == null || f.dir || !isImage(f.name)) {
                continue;
            }
            String stem = stemOf(f.name);
            int rank = rank(stem, folderName);
            if (rank < bestRank) {
                bestRank = rank;
                best = new String[]{f.docId, f.name};
            }
        }
        return best;
    }

    /** 文件所在目录的名字（docId 的倒数第二段）；取不到返回空串。 */
    private static String folderStem(VFile audio) {
        String doc = audio.docId == null ? "" : audio.docId;
        int colon = doc.indexOf(':');
        String path = colon >= 0 ? doc.substring(colon + 1) : doc;
        int slash = path.lastIndexOf('/');
        if (slash <= 0) {
            return "";
        }
        String dir = path.substring(0, slash);
        int prev = dir.lastIndexOf('/');
        return (prev >= 0 ? dir.substring(prev + 1) : dir).toLowerCase(Locale.ROOT).trim();
    }

    /** 数字越小越优先；不认识的图片名排最后（但仍然比「没有」好）。 */
    private static int rank(String stem, String folderName) {
        if (!folderName.isEmpty() && stem.equals(folderName)) {
            return 0;
        }
        for (int i = 0; i < STEMS.length; i++) {
            if (STEMS[i].equals(stem)) {
                return i + 1;
            }
        }
        return STEMS.length + 1;
    }

    private static byte[] load(Storage st, String parentId, String docId, String name) {
        File tmp = null;
        try {
            VFile img = new VFile(docId, parentId, name, mimeOf(name), 0L, 0L, false);
            tmp = File.createTempFile("mo_foldercov_", ".img");
            st.copyToLocal(img, tmp);
            long len = tmp.length();
            if (len <= 0 || len > MAX_BYTES) {
                return null;
            }
            byte[] out = new byte[(int) len];
            FileInputStream in = new FileInputStream(tmp);
            try {
                int read = 0;
                while (read < out.length) {
                    int n = in.read(out, read, out.length - read);
                    if (n <= 0) {
                        break;
                    }
                    read += n;
                }
                return read > 0 ? out : null;
            } finally {
                in.close();
            }
        } catch (Throwable t) {
            return null;
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
    }

    private static boolean isImage(String name) {
        String lower = name == null ? "" : name.toLowerCase(Locale.ROOT);
        for (String ext : EXTS) {
            if (lower.endsWith(ext)) {
                return true;
            }
        }
        return false;
    }

    private static String stemOf(String name) {
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name;
        return stem.trim().toLowerCase(Locale.ROOT);
    }

    private static String mimeOf(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".png")) {
            return "image/png";
        }
        if (lower.endsWith(".webp")) {
            return "image/webp";
        }
        return "image/jpeg";
    }
}
