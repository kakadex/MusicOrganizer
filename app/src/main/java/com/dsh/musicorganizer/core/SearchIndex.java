package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 文件浏览页的内存搜索索引（纯逻辑，桌面 JVM 可测）。
 *
 * <p>为什么不用 SQLite FTS：我们的规模是几千到几万首，内存索引冷构建 100ms 级、
 * 每次查询毫秒级，还省掉建库与迁移；歌词只存前若干行（见 {@link #LYRICS_HEAD}），
 * 内存占用可控。
 *
 * <p>字段在 {@link Entry#renormalize()} 里预先归一（繁转简 + 去标点 + 小写），
 * 查询时只做 {@code contains}，避免每次按键重复做重活。
 */
public final class SearchIndex {

    /** 每首歌最多存这么多字符的歌词用于搜索（约 2000 行正文的 1/4，够命中副歌）。 */
    public static final int LYRICS_HEAD = 20000;

    /** 索引条目：既是搜索单元，也是列表行的数据源。 */
    public static final class Entry {
        public final String docId;
        public final String name;
        public final String relPath;
        public final long size;
        public final long modified;
        /** 音频文件对象；纯测试时可传 null。 */
        public final VFile file;

        public String title = "";
        public String artist = "";
        public String album = "";
        public String genre = "";
        public String comment = "";
        public String year = "";
        /** 歌词（同名 .lrc 或标签里的歌词），只保留前 {@link #LYRICS_HEAD} 字符 */
        public String lyrics = "";

        /** 有没有内嵌封面（未知时 false，读了 meta 才准确） */
        public boolean hasCover;

        /**
         * 时长（毫秒）；0 = 还没读到或取不到（v0.1.51 曲库列表右侧显示用）。
         * 刻意不进快照持久化：读一次只要几毫秒，而快照格式一改就要处理旧版兼容。
         */
        public long durationMs;

        /**
         * 码率（kbps）；0 = 还没读到或取不到。v0.1.51 起显示成「NNNkbps」，
         * 也就是用户说的「曲目质量」。
         */
        public int bitrateKbps;
        /** 有没有歌词（同名 .lrc 或标签内嵌） */
        public boolean hasLyrics;
        /** 标签是否已读过（决定要不要显示「—」与是否参与标签搜索） */
        public boolean metaLoaded;

        private String nName = "";
        private String nPath = "";
        private String nTitle = "";
        private String nArtist = "";
        private String nAlbum = "";
        private String nGenre = "";
        private String nComment = "";
        private String nLyrics = "";
        private String nYear = "";
        private String nExt = "";

        public Entry(String docId, String name, String relPath, long size, long modified,
                     VFile file) {
            this.docId = docId == null ? "" : docId;
            this.name = name == null ? "" : name;
            this.relPath = relPath == null ? "" : relPath;
            this.size = size;
            this.modified = modified;
            this.file = file;
            int dot = this.name.lastIndexOf('.');
            this.nExt = dot < 0 ? "" : this.name.substring(dot + 1).toLowerCase(Locale.ROOT);
            renormalize();
        }

        public String ext() {
            return nExt;
        }

        /** 标题：优先标签，其次文件名（去扩展名）。 */
        public String displayTitle() {
            if (!title.trim().isEmpty()) {
                return title.trim();
            }
            int dot = name.lastIndexOf('.');
            return dot > 0 ? name.substring(0, dot) : name;
        }

        /** 副标题：艺人 · 专辑，缺失时给空串（界面显示「—」）。 */
        public String displaySub() {
            StringBuilder sb = new StringBuilder();
            if (!artist.trim().isEmpty()) {
                sb.append(artist.trim());
            }
            if (!album.trim().isEmpty()) {
                if (sb.length() > 0) {
                    sb.append(" · ");
                }
                sb.append(album.trim());
            }
            return sb.toString();
        }

        /** 标签是否齐（标题 + 艺人 + 专辑都有）。 */
        public boolean tagComplete() {
            return !displayTitle().isEmpty() && !artist.trim().isEmpty()
                    && !album.trim().isEmpty();
        }

        public void applyTags(Tags tags, boolean cover) {
            if (tags != null) {
                title = tags.get("title");
                artist = tags.get("artist");
                album = tags.get("album");
                genre = tags.get("genre");
                comment = tags.get("comment");
                year = tags.get("year");
                String lyric = tags.get("lyrics");
                if (lyric != null && !lyric.trim().isEmpty()) {
                    lyrics = clip(lyric);
                    hasLyrics = true;
                }
            }
            hasCover = cover;
            metaLoaded = true;
            renormalize();
        }

        public void applyLyrics(String text) {
            if (text == null || text.trim().isEmpty()) {
                return;
            }
            lyrics = clip(text);
            hasLyrics = true;
            renormalize();
        }

        private static String clip(String text) {
            return text.length() > LYRICS_HEAD ? text.substring(0, LYRICS_HEAD) : text;
        }

        /** 预计算归一串；任何字段变化后都要调一次。 */
        public void renormalize() {
            nName = SearchQuery.norm(name);
            nPath = SearchQuery.norm(relPath);
            nTitle = SearchQuery.norm(title);
            nArtist = SearchQuery.norm(artist);
            nAlbum = SearchQuery.norm(album);
            nGenre = SearchQuery.norm(genre);
            nComment = SearchQuery.norm(comment);
            nLyrics = SearchQuery.norm(lyrics);
            nYear = SearchQuery.norm(year);
        }
    }

    private final List<Entry> entries = new ArrayList<Entry>();
    private final Map<String, Entry> byId = new HashMap<String, Entry>();

    public void clear() {
        entries.clear();
        byId.clear();
    }

    public int size() {
        return entries.size();
    }

    public List<Entry> all() {
        return entries;
    }

    public Entry find(String docId) {
        return docId == null ? null : byId.get(docId);
    }

    /** 加入索引；同一个 docId 只保留一条（重复会让库页把同一首列两遍）。 */
    public void add(Entry e) {
        if (e == null) {
            return;
        }
        Entry old = byId.get(e.docId);
        if (old != null) {
            int at = entries.indexOf(old);
            if (at >= 0) {
                entries.set(at, e);
            }
            byId.put(e.docId, e);
            return;
        }
        entries.add(e);
        byId.put(e.docId, e);
    }

    /** 已读标签的条数（界面上用来说清「标签搜索覆盖了多少」）。 */
    public int loadedCount() {
        int n = 0;
        for (Entry e : entries) {
            if (e.metaLoaded) {
                n++;
            }
        }
        return n;
    }

    /** 按查询过滤，返回保持原顺序的子集。 */
    public List<Entry> search(SearchQuery q) {
        List<Entry> out = new ArrayList<Entry>();
        if (q == null || q.isEmpty()) {
            out.addAll(entries);
            return out;
        }
        for (Entry e : entries) {
            if (matches(e, q)) {
                out.add(e);
            }
        }
        return out;
    }

    public static boolean matches(Entry e, SearchQuery q) {
        if (q == null) {
            return true;
        }
        if (e.size < q.minSize || (q.maxSize >= 0 && e.size > q.maxSize)) {
            return false;
        }
        for (Map.Entry<String, String> f : q.fields.entrySet()) {
            String value = f.getValue();
            if (value.isEmpty()) {
                continue;
            }
            String target = fieldValue(e, f.getKey());
            if (!target.contains(value)) {
                return false;
            }
        }
        for (String term : q.terms) {
            if (term.isEmpty()) {
                continue;
            }
            if (!anyField(e, term)) {
                return false;
            }
        }
        return true;
    }

    private static String fieldValue(Entry e, String field) {
        if ("title".equals(field)) {
            // 没读过标签时退化为文件名，免得 title:xxx 在未加载的行上永远不命中
            return e.nTitle.isEmpty() ? e.nName : e.nTitle;
        }
        if ("artist".equals(field)) {
            return e.nArtist;
        }
        if ("album".equals(field)) {
            return e.nAlbum;
        }
        if ("genre".equals(field)) {
            return e.nGenre;
        }
        if ("comment".equals(field)) {
            return e.nComment;
        }
        if ("lyrics".equals(field)) {
            return e.nLyrics;
        }
        if ("path".equals(field)) {
            return e.nPath;
        }
        if ("ext".equals(field)) {
            return e.nExt;
        }
        if ("year".equals(field)) {
            return e.nYear;
        }
        return "";
    }

    /** 自由词：文件名 / 路径 / 标签 / 歌词任意命中即可。 */
    private static boolean anyField(Entry e, String term) {
        return e.nName.contains(term)
                || e.nPath.contains(term)
                || e.nTitle.contains(term)
                || SearchQuery.norm(e.displayTitle()).contains(term)
                || e.nArtist.contains(term)
                || e.nAlbum.contains(term)
                || e.nGenre.contains(term)
                || e.nComment.contains(term)
                || e.nLyrics.contains(term);
    }
}
