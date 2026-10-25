package com.dsh.musicorganizer.core;

import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/**
 * SAF 文档抽象：一个 VFile 代表存储访问框架里的一个文件或目录。
 *
 * 以 documentId 为唯一标识（如 primary:Music/a.mp3），所有操作都走 Storage。
 */
public final class VFile {

    public static final Set<String> AUDIO_EXTS = new HashSet<String>();
    public static final Set<String> LYRIC_EXTS = new HashSet<String>();
    public static final Set<String> MUSIC_EXTS = new HashSet<String>();

    static {
        String[] audio = {".mp3", ".flac", ".m4a", ".wav", ".ogg", ".aac", ".wma", ".ape",
                ".opus", ".wv", ".mpc", ".dsf"};
        String[] lyric = {".lrc", ".krc", ".qrc", ".trc", ".srt"};
        for (String s : audio) {
            AUDIO_EXTS.add(s);
        }
        for (String s : lyric) {
            LYRIC_EXTS.add(s);
        }
        MUSIC_EXTS.addAll(AUDIO_EXTS);
        MUSIC_EXTS.addAll(LYRIC_EXTS);
    }

    public final String docId;       // 如 primary:Music/周杰伦/晴天.mp3
    public final String parentId;    // 父目录 docId；根目录为 null
    public final String name;        // 显示名（含扩展名）
    public final String mime;
    public final long size;
    public final long lastModified;
    public final boolean dir;

    // ------------------------------------------------------------------
    // 标签缓存（「库索引」的最小单元）
    // ------------------------------------------------------------------

    /**
     * 上次读到的标签；{@code null} 表示还没读过。
     *
     * <p>存在的意义：列表页原本只把标签放在内存索引里，{@code reload()} 一重建索引
     * 就全部退回「未读」，于是补完一首歌的标签要把整个目录的标签重读一遍。
     * 把结果挂在文件对象上，索引重建、快照恢复、增量扫描都能直接接力，不再重复读盘。
     *
     * <p>只由「标签 + 封面 + 歌词都判断过」的一方写入（浏览页读完后回填、
     * 快照恢复、增量扫描接力），因此非 null 即代表三项都可信。
     *
     * <p>失效规则：{@link Scanner#invalidate(VFile)}（任何写盘之后）与
     * {@link ScanMerge} 判出 size / lastModified 变化时清空。
     */
    public Tags cachedTags;
    /** 上次判定「有内嵌封面」。 */
    public boolean cachedHasCover;
    /** 上次判定「有歌词」（内嵌或同名 .lrc，由浏览页合并）。 */
    public boolean cachedHasLyrics;
    /**
     * 上次读到的时长（毫秒）/ 码率（kbps）。
     *
     * <p>为什么要跟着标签一起缓存：换主题 / 转屏会 {@code recreate()}，库页重建索引时
     * 走的是「缓存直填」这条路，只回填标签的话，列表里时长与质量会集体消失。
     */
    public long cachedDurationMs;
    public int cachedBitrateKbps;

    public VFile(String docId, String parentId, String name, String mime,
                 long size, long lastModified, boolean dir) {
        this.docId = docId;
        this.parentId = parentId;
        this.name = name == null ? "" : name;
        this.mime = mime == null ? "" : mime;
        this.size = size;
        this.lastModified = lastModified;
        this.dir = dir;
    }

    /** 小写扩展名（含点）；无扩展名返回 ""。 */
    public String ext() {
        int dot = name.lastIndexOf('.');
        if (dot < 0) {
            return "";
        }
        return name.substring(dot).toLowerCase(Locale.ROOT);
    }

    /** 去扩展名的基本名。 */
    public String stem() {
        int dot = name.lastIndexOf('.');
        if (dot <= 0) {
            return name;
        }
        return name.substring(0, dot);
    }

    public boolean audio() {
        return !dir && AUDIO_EXTS.contains(ext());
    }

    public boolean lyric() {
        return !dir && LYRIC_EXTS.contains(ext());
    }

    public boolean music() {
        return !dir && MUSIC_EXTS.contains(ext());
    }

    public boolean isHidden() {
        return name.startsWith(".");
    }

    /** 标签是否已缓存（缓存为空也算「读过」，否则无标签的文件每次都要重读）。 */
    public boolean metaCached() {
        return cachedTags != null;
    }

    /** 写入缓存（读盘成功后调用）。存副本：多个 VFile 间不会共享同一个可变对象。 */
    public void cacheMeta(Tags tags, boolean cover, boolean lyrics) {
        cacheMeta(tags, cover, lyrics, 0L, 0);
    }

    /** 同上，并带上时长与码率（列表右侧那三行小字要用）。 */
    public void cacheMeta(Tags tags, boolean cover, boolean lyrics,
                          long durationMs, int bitrateKbps) {
        this.cachedTags = tags == null ? new Tags() : tags.copy();
        this.cachedHasCover = cover;
        this.cachedHasLyrics = lyrics;
        this.cachedDurationMs = durationMs;
        this.cachedBitrateKbps = bitrateKbps;
    }

    /** 丢掉缓存（标签写入 / 外部改动之后必须调用）。 */
    public void clearMeta() {
        cachedTags = null;
        cachedHasCover = false;
        cachedHasLyrics = false;
        cachedDurationMs = 0L;
        cachedBitrateKbps = 0;
    }

    /** 相对根 docId 的路径片段（不含根目录名），用 / 分隔。 */
    public String relativePath(String rootDocId) {
        String prefix = rootDocId.endsWith("/")
                ? rootDocId : rootDocId + "/";
        if (docId.length() > prefix.length() && docId.startsWith(prefix)) {
            return docId.substring(prefix.length());
        }
        return name;
    }

    public String pathAfterRoot() {
        int idx = docId.indexOf(':');
        return idx >= 0 ? docId.substring(idx + 1) : docId;
    }

    @Override
    public String toString() {
        return name;
    }
}
