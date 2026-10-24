package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Reader;
import java.io.Writer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 扫描结果快照：把「上次扫描出来的文件列表 + 分组」落盘，进程被杀 / 闪退后重启能直接恢复。
 *
 * <p>为什么需要它：扫描结果原本只存在 {@code Repo.lastFiles} 里（纯内存），应用一崩就全丢，
 * 用户再打开只看到「还没有音乐文件」，几万首的目录要重新扫一遍 SAF。
 *
 * <p>为什么不干脆启动时重扫：SAF 遍历几千个文件要几十秒，冷启动时后台悄悄扫还很耗电。
 *
 * <p>存的是<b>扫描那一刻的目录快照</b>，不是实时状态：
 * <ul>
 *   <li>用户自己删/加了文件，快照不会知道 —— 所以界面上要标「上次扫描（时间）」，
 *       并提供「扫描」按钮刷新；</li>
 *   <li>文件被外部改动（换了一首）时，列表里的信息可能过期，但点开就是对文件本身操作，
 *       不会写错文件（所有写盘都按 docId 重新打开）。</li>
 * </ul>
 *
 * <p>格式是本项目自己的紧凑 JSON（{@code core/Json}，无第三方依赖）：文件用下标互引，
 * 一万首大约 1MB，读写都在后台线程完成。
 */
public final class ScanSnapshot {

    /**
     * 格式版本。
     *
     * <p>v1：只有文件列表与分组；v2：多了每首歌的标签缓存。
     * {@link #fromJson} 对 v1 仍然兼容（读进来只是没有标签缓存），
     * 免得升级之后用户的列表凭空消失、非得重扫一次。
     */
    private static final int VERSION = 2;

    /** 单文件上限：超过就认为坏了，不解析。 */
    private static final long MAX_BYTES = 32L * 1024 * 1024;

    public String treeUri = "";
    public long savedAt = 0;
    public ScanStats stats = new ScanStats();
    public final List<VFile> files = new ArrayList<VFile>();
    public final List<TrackGroup> groups = new ArrayList<TrackGroup>();

    public boolean isEmpty() {
        return files.isEmpty();
    }

    /** 「3 分钟前」这类相对时间，界面上标「上次扫描」用。 */
    public String ageText() {
        long diff = System.currentTimeMillis() - savedAt;
        if (savedAt <= 0) {
            return "时间未知";
        }
        if (diff < 0) {
            diff = 0;
        }
        long min = diff / 60000L;
        if (min < 1) {
            return "刚刚";
        }
        if (min < 60) {
            return min + " 分钟前";
        }
        long hour = min / 60;
        if (hour < 24) {
            return hour + " 小时前";
        }
        return (hour / 24) + " 天前";
    }

    // ------------------------------------------------------------------
    // 存 / 取 / 清
    // ------------------------------------------------------------------

    /**
     * 落盘（后台线程调用）。
     *
     * @param dir     存放目录（{@code filesDir/scan}）
     * @param treeUri 目录树授权地址：换了目录，快照必须跟着换，不能串
     * @return 写入的文件；失败返回 null（快照只是加速，失败不影响主流程）
     */
    public static File save(File dir, String treeUri, VFile root, List<VFile> files,
                            List<TrackGroup> groups, ScanStats stats) {
        if (dir == null || files == null || files.isEmpty()) {
            return null;
        }
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        File target = fileOf(dir, treeUri);
        File tmp = new File(dir, target.getName() + ".tmp");
        Writer w = null;
        try {
            w = new OutputStreamWriter(new FileOutputStream(tmp), "UTF-8");
            w.write(toJson(treeUri, root, files, groups, stats));
            w.flush();
            w.close();
            w = null;
            if (target.exists() && !target.delete()) {
                // 删不掉旧文件就别强来，直接覆盖写（下面 rename 会失败，退化为直接写目标）
                copy(tmp, target);
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
                return target;
            }
            if (!tmp.renameTo(target)) {
                copy(tmp, target);
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
            return target;
        } catch (Throwable t) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            return null;
        } finally {
            if (w != null) {
                try {
                    w.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    /** 读取快照；目录不匹配 / 版本不符 / 文件损坏都返回 null。 */
    public static ScanSnapshot load(File dir, String treeUri) {
        if (dir == null || treeUri == null || treeUri.isEmpty()) {
            return null;
        }
        File f = fileOf(dir, treeUri);
        if (!f.exists() || f.length() <= 0 || f.length() > MAX_BYTES) {
            return null;
        }
        Reader r = null;
        try {
            r = new InputStreamReader(new FileInputStream(f), "UTF-8");
            StringBuilder sb = new StringBuilder((int) f.length());
            char[] buf = new char[8192];
            int n;
            while ((n = r.read(buf)) > 0) {
                sb.append(buf, 0, n);
            }
            return fromJson(sb.toString(), treeUri);
        } catch (Throwable t) {
            return null;
        } finally {
            if (r != null) {
                try {
                    r.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    /** 清掉所有快照（换目录 / 用户手动清理）。 */
    public static void clear(File dir) {
        if (dir == null || !dir.isDirectory()) {
            return;
        }
        File[] all = dir.listFiles();
        if (all == null) {
            return;
        }
        for (File f : all) {
            //noinspection ResultOfMethodCallIgnored
            f.delete();
        }
    }

    /** 快照文件：按 treeUri 散列命名，多个目录互不干扰。 */
    public static File fileOf(File dir, String treeUri) {
        return new File(dir, "scan-" + hash(treeUri == null ? "" : treeUri) + ".json");
    }

    static String hash(String s) {
        // FNV-1a 32 位：够散、够短，不引 MessageDigest
        int h = 0x811C9DC5;
        for (int i = 0; i < s.length(); i++) {
            h ^= s.charAt(i);
            h *= 0x01000193;
        }
        return String.format("%08x", Integer.valueOf(h));
    }

    private static void copy(File from, File to) throws IOException {
        FileInputStream in = null;
        FileOutputStream out = null;
        try {
            in = new FileInputStream(from);
            out = new FileOutputStream(to);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (IOException ignored) {
                }
            }
            if (out != null) {
                try {
                    out.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // 序列化
    // ------------------------------------------------------------------

    static String toJson(String treeUri, VFile root, List<VFile> files,
                         List<TrackGroup> groups, ScanStats stats) {
        Map<String, Integer> fileIndex = new HashMap<String, Integer>();
        for (int i = 0; i < files.size(); i++) {
            if (!fileIndex.containsKey(files.get(i).docId)) {
                fileIndex.put(files.get(i).docId, Integer.valueOf(i));
            }
        }
        StringBuilder sb = new StringBuilder(files.size() * 96 + 256);
        sb.append("{\"v\":").append(VERSION);
        sb.append(",\"tree\":").append(Json.quote(treeUri == null ? "" : treeUri));
        sb.append(",\"at\":").append(System.currentTimeMillis());
        sb.append(",\"root\":");
        appendDir(sb, root);
        sb.append(",\"stats\":{");
        ScanStats s = stats == null ? new ScanStats() : stats;
        sb.append("\"files\":").append(s.files)
                .append(",\"groups\":").append(s.groups)
                .append(",\"sa\":").append(s.skippedArtist)
                .append(",\"su\":").append(s.skippedUnrecognized)
                .append(",\"ig\":").append(s.ignored)
                .append(",\"au\":").append(s.audio)
                .append(",\"ly\":").append(s.lyrics)
                .append('}');

        sb.append(",\"files\":[");
        for (int i = 0; i < files.size(); i++) {
            VFile f = files.get(i);
            if (i > 0) {
                sb.append(',');
            }
            sb.append("{\"id\":").append(Json.quote(f.docId))
                    .append(",\"pid\":").append(Json.quote(f.parentId))
                    .append(",\"n\":").append(Json.quote(f.name))
                    .append(",\"m\":").append(Json.quote(f.mime))
                    .append(",\"s\":").append(f.size)
                    .append(",\"t\":").append(f.lastModified)
                    .append(",\"d\":").append(f.dir ? 1 : 0);
            // v2：把读到的标签一起存下来，重启后不必重读整库
            if (f.metaCached()) {
                sb.append(",\"cv\":").append(f.cachedHasCover ? 1 : 0)
                        .append(",\"lv\":").append(f.cachedHasLyrics ? 1 : 0)
                        .append(",\"tg\":");
                appendTags(sb, f.cachedTags);
            }
            sb.append('}');
        }
        sb.append(']');

        sb.append(",\"groups\":[");
        boolean first = true;
        if (groups != null) {
            for (TrackGroup g : groups) {
                if (g.audio.isEmpty()) {
                    continue;
                }
                if (!first) {
                    sb.append(',');
                }
                first = false;
                sb.append("{\"b\":").append(Json.quote(g.basename)).append(",\"dir\":");
                appendDir(sb, g.dir);
                sb.append(",\"a\":");
                appendIndexes(sb, g.audio, fileIndex);
                sb.append(",\"l\":");
                appendIndexes(sb, g.lyrics, fileIndex);
                sb.append('}');
            }
        }
        sb.append("]}");
        return sb.toString();
    }

    /** 标签对象：只写非空字段，一万首大约多几百 KB。 */
    private static void appendTags(StringBuilder sb, Tags tags) {
        sb.append('{');
        if (tags != null) {
            boolean first = true;
            for (String k : Tags.KEYS) {
                String v = tags.get(k);
                if (v == null || v.isEmpty()) {
                    continue;
                }
                if (!first) {
                    sb.append(',');
                }
                first = false;
                sb.append(Json.quote(k)).append(':').append(Json.quote(v));
            }
        }
        sb.append('}');
    }

    private static void appendDir(StringBuilder sb, VFile dir) {
        if (dir == null) {
            sb.append("null");
            return;
        }
        sb.append("{\"id\":").append(Json.quote(dir.docId))
                .append(",\"n\":").append(Json.quote(dir.name))
                .append('}');
    }

    private static void appendIndexes(StringBuilder sb, List<VFile> list,
                                      Map<String, Integer> index) {
        sb.append('[');
        boolean first = true;
        for (VFile f : list) {
            Integer i = index.get(f.docId);
            if (i == null) {
                continue;
            }
            if (!first) {
                sb.append(',');
            }
            first = false;
            sb.append(i.intValue());
        }
        sb.append(']');
    }

    @SuppressWarnings("unchecked")
    static ScanSnapshot fromJson(String text, String treeUri) {
        Object parsed = Json.parseOrNull(text);
        if (!(parsed instanceof Map)) {
            return null;
        }
        Map<String, Object> root = (Map<String, Object>) parsed;
        int version = (int) num(root.get("v"));
        if (version < 1 || version > VERSION) {
            return null; // 太老或太新：宁可重扫，不可读歪
        }
        String savedTree = str(root.get("tree"));
        if (!savedTree.equals(treeUri == null ? "" : treeUri)) {
            return null; // 快照属于另一个目录，不能拿来用
        }
        ScanSnapshot snap = new ScanSnapshot();
        snap.treeUri = savedTree;
        snap.savedAt = (long) num(root.get("at"));
        Map<String, Object> st = asMap(root.get("stats"));
        ScanStats stats = new ScanStats();
        stats.files = (int) num(st.get("files"));
        stats.groups = (int) num(st.get("groups"));
        stats.skippedArtist = (int) num(st.get("sa"));
        stats.skippedUnrecognized = (int) num(st.get("su"));
        stats.ignored = (int) num(st.get("ig"));
        stats.audio = (int) num(st.get("au"));
        stats.lyrics = (int) num(st.get("ly"));
        snap.stats = stats;

        Object filesNode = root.get("files");
        // 旧快照里可能已经存在重复条目（v0.1.57 之前 SAF 重复返回同一文档导致）：
        // 读回来时按 docId 去重，免得用户升级后列表还是重复的
        java.util.Set<String> seenIds = new java.util.HashSet<String>();
        if (filesNode instanceof List) {
            for (Object o : (List<Object>) filesNode) {
                if (!(o instanceof Map)) {
                    continue;
                }
                Map<String, Object> m = (Map<String, Object>) o;
                String id = str(m.get("id"));
                if (id.isEmpty()) {
                    continue;
                }
                VFile f = new VFile(id, emptyNull(str(m.get("pid"))), str(m.get("n")),
                        str(m.get("m")), (long) num(m.get("s")), (long) num(m.get("t")),
                        num(m.get("d")) != 0);
                // v2：恢复上次读到的标签，启动后列表直接有标题/歌手，不必重读整库
                Object tg = m.get("tg");
                if (tg instanceof Map) {
                    f.cacheMeta(tagsOf((Map<String, Object>) tg),
                            num(m.get("cv")) != 0, num(m.get("lv")) != 0);
                }
                if (seenIds.add(f.docId)) {
                    snap.files.add(f);
                }
            }
        }
        Map<String, VFile> dirCache = new HashMap<String, VFile>();
        VFile rootDir = dirOf(asMap(root.get("root")), null);
        if (rootDir != null) {
            dirCache.put(rootDir.docId, rootDir);
        }
        Object groupsNode = root.get("groups");
        if (groupsNode instanceof List) {
            for (Object o : (List<Object>) groupsNode) {
                if (!(o instanceof Map)) {
                    continue;
                }
                Map<String, Object> m = (Map<String, Object>) o;
                Map<String, Object> dm = asMap(m.get("dir"));
                String did = str(dm.get("id"));
                VFile dir = dirCache.get(did);
                if (dir == null) {
                    dir = dirOf(dm, rootDir);
                    if (dir != null) {
                        dirCache.put(did, dir);
                    }
                }
                if (dir == null) {
                    continue;
                }
                TrackGroup g = new TrackGroup(dir, str(m.get("b")));
                addFiles(g.audio, m.get("a"), snap.files);
                addFiles(g.lyrics, m.get("l"), snap.files);
                if (!g.audio.isEmpty()) {
                    snap.groups.add(g);
                }
            }
        }
        return snap;
    }

    /** 快照里的文件列表可能被重复引用（同 docId 出现两次），这里按 docId 去重。 */
    private static void addFiles(List<VFile> target, Object node, List<VFile> all) {
        if (!(node instanceof List)) {
            return;
        }
        Set<String> seen = new HashSet<String>();
        for (VFile f : target) {
            seen.add(f.docId);
        }
        for (Object o : (List<Object>) node) {
            int idx = (int) num(o);
            if (idx < 0 || idx >= all.size()) {
                continue;
            }
            VFile f = all.get(idx);
            if (seen.add(f.docId)) {
                target.add(f);
            }
        }
    }

    private static Tags tagsOf(Map<String, Object> m) {
        Tags tags = new Tags();
        if (m == null) {
            return tags;
        }
        for (String k : Tags.KEYS) {
            String v = str(m.get(k));
            if (!v.isEmpty()) {
                tags.put(k, v);
            }
        }
        return tags;
    }

    private static VFile dirOf(Map<String, Object> m, VFile fallback) {
        if (m == null) {
            return fallback;
        }
        String id = str(m.get("id"));
        if (id.isEmpty()) {
            return fallback;
        }
        String name = str(m.get("n"));
        if (name.isEmpty()) {
            int colon = id.indexOf(':');
            int slash = id.lastIndexOf('/');
            name = slash >= 0 ? id.substring(slash + 1)
                    : (colon >= 0 ? id.substring(colon + 1) : id);
        }
        return new VFile(id, null, name, "vnd.android.document/directory", 0, 0, true);
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object o) {
        return o instanceof Map ? (Map<String, Object>) o : new HashMap<String, Object>();
    }

    private static String str(Object o) {
        if (o == null) {
            return "";
        }
        if (o instanceof String) {
            return (String) o;
        }
        return String.valueOf(o);
    }

    private static String emptyNull(String s) {
        return s == null || s.isEmpty() || "null".equals(s) ? null : s;
    }

    private static double num(Object o) {
        return o instanceof Number ? ((Number) o).doubleValue() : 0d;
    }
}
