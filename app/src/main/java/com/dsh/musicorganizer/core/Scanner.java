package com.dsh.musicorganizer.core;

import android.content.ContentResolver;
import android.net.Uri;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 扫描与分组 —— 对应 Python 版 scan_groups / scan_music_files。
 *
 * 分组键 = (父目录, 基名)；「已归位歌手目录」走三重判定（简化为
 * 文件名分隔符匹配 + 纯歌名目录启发 + 标签 artist 匹配，标签最多读 3 个文件）。
 */
public final class Scanner {

    private Scanner() {
    }

    private static final Set<String> GENERIC_FOLDER_NAMES = new HashSet<String>();

    static {
        String[] arr = {
                "music", "songs", "song", "downloads", "download", "album", "albums",
                "ost", "soundtrack", "soundtracks", "audio", "musics", "library",
                "musiclibrary", "mymusic", "newfolder", "media", "tracks",
                "音乐", "歌曲", "下载", "专辑", "歌单", "音频", "音乐库", "我的音乐",
                "新建文件夹", "未分类", "待整理", "整理", "其他",
        };
        for (String s : arr) {
            GENERIC_FOLDER_NAMES.add(s);
        }
    }

    /**
     * 扫描统计。字段与语义都在 {@link ScanStats} 里（那边是纯 Java，可离线单测）；
     * 这里保留同名子类，是为了不惊动几十处 {@code new Scanner.Stats()} 的调用点。
     */
    public static class Stats extends ScanStats {
    }

    /** 识别「已归位」的歌手目录，返回其 docId 集合。 */
    public static Set<String> artistDirIds(Storage st, VFile root,
                                           ContentResolver resolver, Progress progress) {
        Set<String> result = new HashSet<String>();
        int checked = 0;
        for (VFile entry : st.children(root)) {
            if (!entry.dir || entry.isHidden()) {
                continue;
            }
            if (entry.name.equalsIgnoreCase(TextUtil.UNRECOGNIZED_DIR)) {
                continue;
            }
            String folderNorm = TextUtil.normCompare(TextUtil.toSimplified(entry.name));
            if (folderNorm.isEmpty() || GENERIC_FOLDER_NAMES.contains(folderNorm)) {
                continue;
            }
            List<VFile> directFiles = new ArrayList<VFile>();
            for (VFile c : st.children(entry)) {
                if (!c.dir && c.music()) {
                    directFiles.add(c);
                }
            }
            if (directFiles.isEmpty()) {
                continue;
            }
            if (matchesArtistDir(st, resolver, entry, folderNorm, directFiles)) {
                result.add(entry.docId);
            }
            checked++;
            if (progress != null && checked % 5 == 0) {
                progress.onProgress(checked, 0, "正在识别歌手目录：" + entry.name);
            }
        }
        return result;
    }

    private static boolean matchesArtistDir(Storage st, ContentResolver resolver,
                                            VFile dir, String folderNorm, List<VFile> files) {
        List<VFile> audio = new ArrayList<VFile>();
        for (VFile f : files) {
            if (f.audio()) {
                audio.add(f);
            }
        }
        // 判定 1：标签 artist 与目录名相容（最多读 3 个）
        int tagReads = 0;
        for (VFile f : audio) {
            if (tagReads >= 3) {
                break;
            }
            tagReads++;
            Tags tags = readTagsCheap(st, resolver, f);
            String artist = tags.get("artist");
            if (!artist.isEmpty() && ArtistRules.artistsCompatible(dir.name, artist)) {
                return true;
            }
        }
        // 判定 2：文件名「歌手 - 歌名」两侧之一与目录名一致
        for (VFile f : files) {
            NameParser.Split split = NameParser.splitArtistTitle(f.stem());
            if (split == null) {
                continue;
            }
            if (TextUtil.normCompare(TextUtil.toSimplified(split.left)).equals(folderNorm)
                    || TextUtil.normCompare(TextUtil.toSimplified(split.right)).equals(folderNorm)) {
                return true;
            }
        }
        // 判定 3：全部音频都是纯歌名（无分隔符）→ 视为单曲目录
        boolean anyAudio = false;
        for (VFile f : audio) {
            anyAudio = true;
            if (NameParser.splitArtistTitle(f.stem()) != null) {
                return false;
            }
        }
        return anyAudio;
    }

    /** docId 是否处于任一歌手目录之下。 */
    private static boolean underArtistDir(String docId, Set<String> artistDirIds) {
        for (String dirId : artistDirIds) {
            if (docId.startsWith(dirId + "/")) {
                return true;
            }
        }
        return false;
    }

    /** 递归收集音乐文件。 */
    public static List<VFile> walkMusic(Storage st, VFile root, boolean recursive,
                                        Progress progress, CancelToken cancel) {
        return walkMusic(st, root, recursive, progress, cancel, null);
    }

    /**
     * 同 {@link #walkMusic}，并把「被忽略的重复条目数」写进 {@code dupOut[0]}。
     *
     * <p>为什么需要这个计数：部分 provider 会把同一个文档返回多次，去重后曲目数才对。
     * 日志里报出来，用户看到「1213 首」和播放器的「911 首」不一致时能立刻判断是哪种情况。
     */
    public static List<VFile> walkMusic(Storage st, VFile root, boolean recursive,
                                        Progress progress, CancelToken cancel, int[] dupOut) {
        List<VFile> out = new ArrayList<VFile>();
        // 同一个 docId 只收一次（v0.1.57）：某些 provider 的 SAF 查询会重复返回同一文档，
        // 目录重复 → 整棵子树被走两遍 → 库页把同一首歌列成两条、曲目数翻倍。
        java.util.Set<String> visited = new java.util.HashSet<String>();
        collect(st, root, recursive, out, progress, cancel, visited, dupOut);
        return out;
    }

    private static void collect(Storage st, VFile dir, boolean recursive,
                                List<VFile> out, Progress progress, CancelToken cancel,
                                java.util.Set<String> visited, int[] dupOut) {
        if (cancel != null && cancel.isCancelled()) {
            return;
        }
        for (VFile c : st.children(dir)) {
            if (cancel != null && cancel.isCancelled()) {
                return;
            }
            if (!visited.add(c.docId)) {
                if (dupOut != null) {
                    dupOut[0]++;
                }
                continue;
            }
            if (c.dir) {
                if (recursive && !c.isHidden()) {
                    collect(st, c, true, out, progress, cancel, visited, dupOut);
                }
            } else if (c.music() && !c.isHidden()) {
                out.add(c);
            }
        }
    }

    /**
     * 递归列出目录下所有文件（含非音乐文件），用于垃圾清理之类的全量遍历。
     *
     * <p>与 {@link #walkMusic} 不同：这里不排除 {@code .lrc.bak} / {@code .tmp} /
     * {@code Thumbs.db} 这类文件 —— 垃圾清理恰恰要在它们里面找候选。隐藏文件与目录照例跳过。
     * 目录深度上限 64 层，防御符号链接环之类的异常深树。
     */
    public static List<VFile> walkAll(Storage st, VFile root,
                                      Progress progress, CancelToken cancel) {
        List<VFile> out = new ArrayList<VFile>();
        walkAllInto(st, root, out, progress, cancel, 0);
        return out;
    }

    private static void walkAllInto(Storage st, VFile dir, List<VFile> out,
                                    Progress progress, CancelToken cancel, int depth) {
        if (cancel != null && cancel.isCancelled()) {
            return;
        }
        if (depth > 64) {
            return;
        }
        for (VFile c : st.children(dir)) {
            if (cancel != null && cancel.isCancelled()) {
                return;
            }
            if (c.dir) {
                if (!c.isHidden()) {
                    walkAllInto(st, c, out, progress, cancel, depth + 1);
                }
            } else if (!c.isHidden()) {
                out.add(c);
                if (progress != null && out.size() % 200 == 0) {
                    progress.onProgress(out.size(), out.size(), "正在扫描：" + c.name);
                }
            }
        }
    }

    /** 扫描并按 (目录, 基名) 分组。 */
    public static List<TrackGroup> scanGroups(Storage st, VFile root,
                                              boolean recursive,
                                              boolean skipArtistDirs,
                                              boolean includeUnrecognized,
                                              ContentResolver resolver,
                                              Stats stats,
                                              Progress progress,
                                              CancelToken cancel) {
        List<VFile> files = walkMusic(st, root, recursive, progress, cancel);
        Set<String> artistDirs = new HashSet<String>();
        if (skipArtistDirs) {
            artistDirs = artistDirIds(st, root, resolver, progress);
        }
        Map<String, TrackGroup> buckets = new HashMap<String, TrackGroup>();
        int done = 0;
        for (VFile f : files) {
            done++;
            if (progress != null && done % 20 == 0) {
                progress.onProgress(done, files.size(), "正在分组：" + f.name);
            }
            if (cancel != null && cancel.isCancelled()) {
                break;
            }
            // 总数要在「跳过」之前数：用户要的是「这个目录里到底有几首歌」，
            // 而不是「这次有多少个文件被跳过」。歌词单独计数，不混进曲目数。
            if (f.audio()) {
                stats.audio++;
            } else {
                stats.lyrics++;
            }
            if (!includeUnrecognized && isUnderUnrecognized(f, root)) {
                stats.skippedUnrecognized++;
                continue;
            }
            if (skipArtistDirs && underArtistDir(f.docId, artistDirs)) {
                stats.skippedArtist++;
                continue;
            }
            String key = f.parentId + "|" + f.stem().toLowerCase();
            TrackGroup group = buckets.get(key);
            if (group == null) {
                group = new TrackGroup(dirOf(st, root, f), f.stem());
                buckets.put(key, group);
            }
            if (f.audio()) {
                group.audio.add(f);
            } else {
                group.lyrics.add(f);
            }
            stats.files++;
        }
        List<TrackGroup> groups = new ArrayList<TrackGroup>(buckets.values());
        for (TrackGroup g : groups) {
            if (g.audio.isEmpty()) {
                // 无音频、只有歌词的组不参与整理
            }
        }
        List<TrackGroup> valid = new ArrayList<TrackGroup>();
        for (TrackGroup g : groups) {
            if (!g.audio.isEmpty()) {
                valid.add(g);
            }
        }
        java.util.Collections.sort(valid, new java.util.Comparator<TrackGroup>() {
            @Override
            public int compare(TrackGroup a, TrackGroup b) {
                int d = a.dir.docId.compareTo(b.dir.docId);
                if (d != 0) {
                    return d;
                }
                return a.basename.toLowerCase().compareTo(b.basename.toLowerCase());
            }
        });
        stats.groups = valid.size();
        return valid;
    }

    /** 所有音乐文件（含歌词），供浏览器 / 清理 / 查重使用。 */
    public static List<VFile> scanMusicFiles(Storage st, VFile root, boolean recursive,
                                             boolean includeLyricsOnly,
                                             ContentResolver resolver,
                                             Progress progress, CancelToken cancel) {
        List<VFile> files = walkMusic(st, root, recursive, progress, cancel);
        java.util.Collections.sort(files, new java.util.Comparator<VFile>() {
            @Override
            public int compare(VFile a, VFile b) {
                int d = a.parentId.compareTo(b.parentId);
                if (d != 0) {
                    return d;
                }
                return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            }
        });
        return files;
    }

    private static boolean isUnderUnrecognized(VFile f, VFile root) {
        String rel = f.pathAfterRoot();
        String rootPath = root.pathAfterRoot();
        if (!rootPath.isEmpty() && rel.startsWith(rootPath)) {
            rel = rel.substring(rootPath.length());
            if (rel.startsWith("/")) {
                rel = rel.substring(1);
            }
        }
        int slash = rel.indexOf('/');
        String first = slash >= 0 ? rel.substring(0, slash) : "";
        return first.equalsIgnoreCase(TextUtil.UNRECOGNIZED_DIR);
    }

    /** 按文件 docId 反推目录 VFile（找不到就返回根目录）。 */
    public static VFile dirOf(Storage st, VFile root, VFile file) {
        if (file.parentId == null || file.parentId.equals(root.docId)) {
            return root;
        }
        VFile dir = st.stat(file.parentId, null);
        return dir != null ? dir : root;
    }

    // ------------------------------------------------------------------
    // 标签读取（复制到缓存 → 解析；带 MMR 兜底）
    // ------------------------------------------------------------------

    /** 并发安全：批量标签/歌词会多线程同时读标签。 */
    private static final Map<String, Tags> TAG_CACHE =
            new java.util.concurrent.ConcurrentHashMap<String, Tags>();

    /**
     * 读标签时最多复制文件头部这么多字节。
     * 标签（ID3 / Vorbis Comment）都在文件头；只有封面等超大且标签越过 2MB 时才回退整文件复制。
     */
    private static final int HEAD_BYTES = 2 * 1024 * 1024;

    /** 标签 + 封面一次读完的结果（v0.1.54）。 */
    public static final class Head {
        public Tags tags = new Tags();
        /** 内嵌封面字节；没有或读不出为 null。 */
        public byte[] cover;
        /** 是否真的读到（文件打不开时为 false）。 */
        public boolean ok;
    }

    /**
     * 一次复制同时读标签与封面（v0.1.54）。
     *
     * <p>为什么要有它：以前列表每首会复制**两次**文件头（一次读标签、一次读封面），
     * 再各解析一遍，1213 首要跑十几分钟。这里只复制一次，标签与封面都从同一个临时文件解析。
     *
     * <p>复制策略是「能少就少」：先 512KB，标签没读完再扩到 2MB，还不够才整文件复制。
     * 绝大多数 MP3 的标签都在 512KB 内，等于 IO 降到原来的 1/8。
     */
    public static Head readHead(Storage st, VFile f) {
        Head out = new Head();
        if (st == null || f == null) {
            return out;
        }
        File tmp = null;
        try {
            String ext = TagIO.extOf(f.name);
            tmp = File.createTempFile("mo_head_", ext);
            int copied = st.copyHeadToLocal(f, tmp, HEAD_SMALL);
            if (copied >= HEAD_SMALL && !TagIO.tagFitsCopy(tmp, ext)) {
                copied = st.copyHeadToLocal(f, tmp, HEAD_BYTES);
                if (copied >= HEAD_BYTES && !TagIO.tagFitsCopy(tmp, ext)) {
                    st.copyToLocal(f, tmp);
                }
            }
            out.tags = TagIO.readLocal(tmp);
            out.cover = CoverReader.read(tmp);
            out.ok = true;
        } catch (Throwable ignored) {
            // 单首读不出来不影响整批：调用方按「空标签」处理
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
        return out;
    }

    /** 先试这么多字节（标签通常都在里面）；不够再扩展。 */
    private static final int HEAD_SMALL = 512 * 1024;

    /** 低成本标签读取：有缓存直接返回；否则只复制文件头部解析（不够再回退整文件）。 */
    /** 已经为「缓存里没歌词」的文件重读盘确认过的集合（docId|size|mtime）。 */
    private static final java.util.Set<String> LYRICS_PROBED =
            java.util.concurrent.ConcurrentHashMap.newKeySet();

    /** 缓存里没有歌词、且还没重读过 → 需要重读盘确认（旧快照可能没把内嵌歌词读进缓存）。 */
    public static boolean lyricsNeedProbe(VFile f) {
        if (f == null || !f.metaCached()) {
            return false;
        }
        String lyric = f.cachedTags.get(Tags.LYRICS);
        if (lyric != null && !lyric.trim().isEmpty()) {
            return false;
        }
        String key = f.docId + "|" + f.size + "|" + f.lastModified;
        return !LYRICS_PROBED.contains(key);
    }

    /** 标记这个文件已做过「无歌词」重读确认。 */
    public static void markLyricsProbed(VFile f) {
        if (f == null) {
            return;
        }
        LYRICS_PROBED.add(f.docId + "|" + f.size + "|" + f.lastModified);
    }

    public static Tags readTagsCheap(Storage st, ContentResolver resolver, VFile f) {
        if (f == null) {
            return new Tags();
        }
        String probeKey = f.docId + "|" + f.size + "|" + f.lastModified;
        // 库索引已经读过这一首（且 size / lastModified 没变）→ 直接用，不再碰磁盘。
        // 这是「补完一首歌不必重扫整个目录」的关键：索引重建时也走这条快路。
        // 但歌词字段可能被旧版本漏读进缓存：缓存里没有歌词时，重读一次确认（只重读一次）。
        if (f.metaCached()) {
            String lyric = f.cachedTags.get(Tags.LYRICS);
            if (lyric != null && !lyric.trim().isEmpty()) {
                return f.cachedTags.copy();
            }
            if (LYRICS_PROBED.contains(probeKey)) {
                return f.cachedTags.copy();
            }
        }
        String key = probeKey;
        Tags cached = TAG_CACHE.get(key);
        if (cached != null) {
            return cached;
        }
        Tags tags = new Tags();
        File tmp = null;
        try {
            tmp = File.createTempFile("mo_tag_", TagIO.extOf(f.name));
            String ext = TagIO.extOf(f.name);
            int copied = st.copyHeadToLocal(f, tmp, HEAD_BYTES);
            // 头部可能截断了标签区（大封面等）→ 回退整文件复制，保证字段读全
            if (copied >= HEAD_BYTES && !TagIO.tagFitsCopy(tmp, ext)) {
                st.copyToLocal(f, tmp);
            }
            tags = TagIO.readLocal(tmp);
            if (!tags.anyValue()) {
                Tags fallback = MediaMeta.basicTags(resolver, st.documentUri(f), key);
                for (String k : Tags.KEYS) {
                    if (tags.get(k).isEmpty()) {
                        tags.put(k, fallback.get(k));
                    }
                }
            }
        } catch (Exception ignored) {
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
        LYRICS_PROBED.add(probeKey);
        if (TAG_CACHE.size() > 2048) {
            TAG_CACHE.clear();
        }
        TAG_CACHE.put(key, tags);
        return tags;
    }

    /** 读取时长（秒）。 */
    public static Double durationOf(Storage st, ContentResolver resolver, VFile f) {
        String key = f.docId + "|" + f.size + "|" + f.lastModified;
        return MediaMeta.duration(resolver, st.documentUri(f), key);
    }

    // ------------------------------------------------------------------
    // 封面（列表徽标 / 单文件编辑器用）
    // ------------------------------------------------------------------

    private static final Map<String, Boolean> COVER_CACHE =
            new java.util.concurrent.ConcurrentHashMap<String, Boolean>();

    /** 判断里只复制这么多字节就够看到 APIC/PICTURE/covr 的头。 */
    /**
     * 探测封面时复制多少字节。
     *
     * <p>以前是 1MB，可封面在标签里往往排在歌词之后 —— 标签一大（带逐字歌词、
     * 多张图）封面就落在 1MB 之外，探测直接判「无封面」，于是列表里永远空白。
     * 现在与真正读封面用同一档（2MB），探不到再交给框架的 getEmbeddedPicture 兜底。
     */
    private static final int COVER_PROBE_BYTES = HEAD_BYTES;

    /** 有没有内嵌封面。只对可写格式判断（其它格式写了也不支持）。 */
    public static boolean hasCover(Storage st, ContentResolver resolver, VFile f) {
        if (f == null || f.dir || !TagIO.canWrite(f.ext())) {
            return false;
        }
        if (f.metaCached()) {
            return f.cachedHasCover;
        }
        String key = f.docId + "|" + f.size + "|" + f.lastModified;
        Boolean cached = COVER_CACHE.get(key);
        if (cached != null) {
            return cached.booleanValue();
        }
        boolean out = readCoverWith(st, f, COVER_PROBE_BYTES, true) != null;
        if (COVER_CACHE.size() > 4096) {
            COVER_CACHE.clear();
        }
        COVER_CACHE.put(key, Boolean.valueOf(out));
        return out;
    }

    /** 读出内嵌封面的字节；没有则返回 null。 */
    public static byte[] readCover(Storage st, ContentResolver resolver, VFile f) {
        if (f == null || f.dir || !TagIO.canWrite(f.ext())) {
            return null;
        }
        return readCoverWith(st, f, HEAD_BYTES, false);
    }

    private static byte[] readCoverWith(Storage st, VFile f, int headBytes, boolean probeOnly) {
        File tmp = null;
        try {
            tmp = File.createTempFile("mo_cov_", TagIO.extOf(f.name));
            int copied = st.copyHeadToLocal(f, tmp, headBytes);
            String ext = TagIO.extOf(f.name);
            // 头部可能截断了标签区（大封面），回退整文件复制再试一次
            if (!probeOnly && copied >= headBytes && !TagIO.tagFitsCopy(tmp, ext)) {
                st.copyToLocal(f, tmp);
            }
            return probeOnly ? (CoverReader.has(tmp) ? new byte[0] : null) : CoverReader.read(tmp);
        } catch (Exception e) {
            return null;
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
    }

    public static void clearTagCache() {
        TAG_CACHE.clear();
        COVER_CACHE.clear();
        MediaMeta.invalidate(null);
    }

    /**
     * 丢掉单个文件的标签缓存 —— <b>任何标签写入之后必须调用</b>。
     *
     * <p>为什么不能只靠缓存键自然失效：键是 {@code docId|size|lastModified}，
     * 而 {@link VFile} 的 size / lastModified 是 final 字段，写盘后对象里的值不会更新，
     * 于是写完再读会命中写入前的旧标签。事务层拿旧值跟期望值比，必然判「回读校验失败」，
     * 整批都会误报失败（v0.1.2 就栽在这里：110 首全失败，文件其实没被改坏）。
     */
    /**
     * 丢缓存（按文件对象）：除了内存缓存，还要清掉挂在 {@link VFile} 上的库索引缓存。
     *
     * <p>写盘之后调用它，下一次读标签才会真的回源；否则列表会继续显示写入前的标题。
     */
    public static void invalidate(VFile f) {
        if (f == null) {
            invalidate((String) null);
            return;
        }
        f.clearMeta();
        invalidate(f.docId);
    }

    public static void invalidate(String docId) {
        if (docId == null) {
            clearTagCache();
            return;
        }
        String prefix = docId + "|";
        java.util.Iterator<String> it = TAG_CACHE.keySet().iterator();
        while (it.hasNext()) {
            if (it.next().startsWith(prefix)) {
                it.remove();
            }
        }
        java.util.Iterator<String> cov = COVER_CACHE.keySet().iterator();
        while (cov.hasNext()) {
            if (cov.next().startsWith(prefix)) {
                cov.remove();
            }
        }
        MediaMeta.invalidate(docId);
    }

    /** 供 Storage 无关场景构建 Uri（文档 URI）。 */
    public static Uri uriOf(Storage st, VFile f) {
        return st.documentUri(f);
    }
}
