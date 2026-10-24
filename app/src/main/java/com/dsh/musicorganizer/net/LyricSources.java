package com.dsh.musicorganizer.net;

import com.dsh.musicorganizer.core.TextUtil;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * LRCLIB 之外的歌词源 —— 补「国内网络连不上 lrclib.net」这个最大短板。
 *
 * <p>为什么需要它：标签早就是 7 源聚合，歌词却只有 LRCLIB 一家（境外站）。
 * 国内网络下它经常连不上，于是中文歌的歌词匹配率被这一条通道卡死。
 *
 * <p>本类只负责「按歌名/艺人去搜，把候选和它的歌词原样取回来」，
 * <b>不做最终取舍</b> —— 谁对谁错、时长差多少、是不是伴奏版，全部交给
 * {@code core.Lyrics} 统一判定，避免每个源一套标准、标准还互相打架。
 *
 * <table>
 *   <tr><th>源</th><th>接口</th><th>歌词形态</th></tr>
 *   <tr><td>网易云</td><td>{@code /api/search/get/web} → {@code /api/song/lyric}</td><td>LRC 时间轴</td></tr>
 *   <tr><td>QQ 音乐</td><td>{@code client_search_cp} → {@code fcg_query_lyric_new.fcg}</td><td>LRC 时间轴（可能 base64）</td></tr>
 *   <tr><td>lyrics.ovh</td><td>{@code /v1/artist/title}</td><td>纯文本</td></tr>
 * </table>
 */
public final class LyricSources {

    private LyricSources() {
    }

    public static final String NETEASE = "netease";
    public static final String QQMUSIC = "qqmusic";
    public static final String OVH = "lyricsovh";
    /** 酷狗（v0.1.41）：搜索 + 下载，优先 KRC 逐字，失败降级为明文 LRC。 */
    public static final String KUGOU = "kugou";

    /** 单个请求的读取超时；连接超时由 Http 统一压到 3.5s。 */
    private static final int TIMEOUT_MS = 5000;

    /**
     * 搜索结果里最多对几条去取歌词。
     * 每条候选都要再发一次请求，取太多会把「多源兜底」变成「多源拖慢」。
     */
    private static final int MAX_LYRIC_FETCH = 2;

    /** 统一的候选歌词。各源字段不同，在这里抹平。 */
    public static class Hit {
        public String source = "";
        public String title = "";
        public String artist = "";
        public Double duration = null;
        /** 带时间轴的 LRC */
        public String synced = "";
        /** 只有文本、没有时间轴 */
        public String plain = "";
        /** 译文轨（网易 tlyric / QQ trans），与 synced 同一套时间点，可能为空 */
        public String translation = "";

        public boolean hasLyrics() {
            return !synced.isEmpty() || !plain.isEmpty();
        }
    }

    public static String label(String source) {
        if (NETEASE.equals(source)) {
            return "网易云";
        }
        if (QQMUSIC.equals(source)) {
            return "QQ 音乐";
        }
        if (OVH.equals(source)) {
            return "lyrics.ovh";
        }
        if (KUGOU.equals(source)) {
            return "酷狗";
        }
        return source;
    }

    // ------------------------------------------------------------------
    // 网易云
    // ------------------------------------------------------------------

    /**
     * 网易云：搜索 → 取前几条最像的候选 → 逐个取歌词。
     * 歌词在 {@code lrc.lyric}，是标准的 LRC 时间轴文本。
     */
    public static List<Hit> netease(String title, String artist, Double duration) {
        List<Hit> out = new ArrayList<Hit>();
        String q = (safe(artist) + " " + safe(title)).trim();
        if (q.isEmpty()) {
            return out;
        }
        Map<String, String> headers = new HashMap<String, String>();
        headers.put("Referer", "https://music.163.com/");
        // 匿名请求要带 appver，否则 /api/search/get/web 直接返 405「操作频繁」
        headers.put("Cookie", "appver=2.0.2");

        Map<String, String> params = new HashMap<String, String>();
        params.put("s", q);
        params.put("type", "1");
        params.put("offset", "0");
        params.put("limit", "6");
        Object payload = Http.getJson(Endpoints.url("lyric_netease", 0),
                params, headers, TIMEOUT_MS);
        if (!(payload instanceof JSONObject)) {
            return out;
        }
        JSONObject result = ((JSONObject) payload).optJSONObject("result");
        if (result == null) {
            return out;
        }
        JSONArray songs = result.optJSONArray("songs");
        if (songs == null) {
            return out;
        }

        List<Pick> picks = new ArrayList<Pick>();
        for (int i = 0; i < songs.length(); i++) {
            JSONObject s = songs.optJSONObject(i);
            if (s == null) {
                continue;
            }
            Pick p = new Pick();
            p.node = s;
            p.title = s.optString("name", "");
            p.artist = joinArtists(s.optJSONArray("artists"));
            long dur = s.optLong("duration", 0);
            if (dur > 0) {
                p.duration = dur / 1000.0;
            }
            p.order = i;
            p.score = roughScore(title, artist, duration, p.title, p.artist, p.duration);
            picks.add(p);
        }
        sortPicks(picks);

        int fetched = 0;
        for (Pick p : picks) {
            if (fetched >= MAX_LYRIC_FETCH) {
                break;
            }
            long id = p.node.optLong("id", 0);
            if (id <= 0) {
                continue;
            }
            fetched++;
            Map<String, String> lp = new HashMap<String, String>();
            lp.put("id", String.valueOf(id));
            // lv/kv/tv 全给 -1 才是「有就都给我」：只给 lv=1 时 tlyric 整段为空
            lp.put("lv", "-1");
            lp.put("kv", "-1");
            lp.put("tv", "-1");
            Object lyricPayload = Http.getJson(Endpoints.url("lyric_netease", 1),
                    lp, headers, TIMEOUT_MS);
            if (!(lyricPayload instanceof JSONObject)) {
                continue;
            }
            JSONObject lrc = ((JSONObject) lyricPayload).optJSONObject("lrc");
            String text = lrc == null ? "" : lrc.optString("lyric", "");
            if (text.trim().isEmpty()) {
                continue;
            }
            Hit h = new Hit();
            h.source = NETEASE;
            h.title = p.title;
            h.artist = p.artist;
            h.duration = p.duration;
            h.synced = text;
            JSONObject tlyric = ((JSONObject) lyricPayload).optJSONObject("tlyric");
            if (tlyric != null) {
                h.translation = tlyric.optString("lyric", "");
            }
            out.add(h);
        }
        return out;
    }

    // ------------------------------------------------------------------
    // QQ 音乐
    // ------------------------------------------------------------------

    /**
     * QQ 音乐：搜索拿 {@code songmid} → 取歌词。
     * 歌词接口偶尔无视 {@code nobase64=1} 仍返回 base64，所以这里做一次兜底解码；
     * 有时还会被 JSONP 包裹，先剥回调再解析。
     */
    public static List<Hit> qq(String title, String artist, Double duration) {
        List<Hit> out = new ArrayList<Hit>();
        String q = (safe(artist) + " " + safe(title)).trim();
        if (q.isEmpty()) {
            return out;
        }
        Map<String, String> params = new HashMap<String, String>();
        // 旧的 client_search_cp 已返 500，改走网页版 musicu.fcg（与标签源同一套接口）
        JSONObject inner = new JSONObject();
        JSONObject comm = new JSONObject();
        JSONObject req = new JSONObject();
        JSONObject root = new JSONObject();
        try {
            inner.put("num_per_page", 6);
            inner.put("page_num", 1);
            inner.put("query", q);
            req.put("method", "DoSearchForQQMusicDesktop");
            req.put("module", "music.search.SearchCgiService");
            req.put("param", inner);
            comm.put("ct", 19);
            comm.put("cv", 1859);
            comm.put("uin", 0);
            root.put("comm", comm);
            root.put("req", req);
        } catch (Exception e) {
            return out;
        }
        params.put("data", root.toString());
        Map<String, String> headers = new HashMap<String, String>();
        headers.put("Referer", "https://y.qq.com/");
        Object payload = Http.getJson(Endpoints.url("lyric_qq", 0),
                params, headers, TIMEOUT_MS);
        if (!(payload instanceof JSONObject)) {
            return out;
        }
        JSONObject reqNode = ((JSONObject) payload).optJSONObject("req");
        JSONObject data = reqNode == null ? null : reqNode.optJSONObject("data");
        JSONObject body = data == null ? null : data.optJSONObject("body");
        JSONObject song = body == null ? null : body.optJSONObject("song");
        if (song == null) {
            return out;
        }
        JSONArray list = song.optJSONArray("list");
        if (list == null) {
            return out;
        }

        List<Pick> picks = new ArrayList<Pick>();
        for (int i = 0; i < list.length(); i++) {
            JSONObject s = list.optJSONObject(i);
            if (s == null) {
                continue;
            }
            Pick p = new Pick();
            p.node = s;
            p.title = s.optString("name", s.optString("title", ""));
            p.artist = joinArtists(s.optJSONArray("singer"));
            long dur = s.optLong("interval", 0);
            if (dur > 0) {
                p.duration = (double) dur;
            }
            p.order = i;
            p.score = roughScore(title, artist, duration, p.title, p.artist, p.duration);
            picks.add(p);
        }
        sortPicks(picks);

        Map<String, String> lyricHeaders = new HashMap<String, String>();
        lyricHeaders.put("Referer", "https://y.qq.com/portal/player.html");

        int fetched = 0;
        for (Pick p : picks) {
            if (fetched >= MAX_LYRIC_FETCH) {
                break;
            }
            // 新搜索接口里歌单唯一标识字段是 mid（老接口叫 songmid）
            String mid = p.node.optString("mid", p.node.optString("songmid", ""));
            if (mid.isEmpty()) {
                continue;
            }
            fetched++;
            Map<String, String> lp = new HashMap<String, String>();
            lp.put("songmid", mid);
            lp.put("format", "json");
            lp.put("nobase64", "1");
            lp.put("g_tk", "5381");
            String raw = Http.getText(Endpoints.url("lyric_qq", 1),
                    lp, lyricHeaders, TIMEOUT_MS);
            String lyric = parseQqLyric(raw);
            if (lyric.trim().isEmpty()) {
                continue;
            }
            Hit h = new Hit();
            h.source = QQMUSIC;
            h.title = p.title;
            h.artist = p.artist;
            h.duration = p.duration;
            h.synced = lyric;
            // QQ 的 trans 覆盖不稳（很多曲子为空串），有就用、没有不影响原文
            h.translation = parseQqTrans(raw);
            out.add(h);
        }
        return out;
    }

    /** 剥 JSONP 包裹 → 取 lyric 字段 → 必要时 base64 解码 → 反转义 HTML 实体。 */
    private static String parseQqLyric(String raw) {
        if (raw == null) {
            return "";
        }
        String text = raw.trim();
        int brace = text.indexOf('{');
        if (brace > 0) {
            text = text.substring(brace);
        }
        int close = text.lastIndexOf('}');
        if (close >= 0 && close < text.length() - 1) {
            text = text.substring(0, close + 1);
        }
        JSONObject node;
        try {
            node = new JSONObject(text);
        } catch (Exception e) {
            return "";
        }
        String lyric = node.optString("lyric", "");
        if (lyric.isEmpty()) {
            return "";
        }
        if (lyric.indexOf('[') < 0) {
            // 没有时间轴前缀，多半是被 base64 了
            try {
                byte[] decoded = android.util.Base64.decode(lyric,
                        android.util.Base64.DEFAULT);
                String plain = new String(decoded, "UTF-8");
                if (plain.indexOf('[') >= 0) {
                    lyric = plain;
                }
            } catch (Exception ignored) {
            }
        }
        return unescapeHtml(lyric);
    }

    /** 取 QQ 返回里的 {@code trans}（译文），解析规则与 lyric 相同（可能 base64 / JSONP）。 */
    private static String parseQqTrans(String raw) {
        if (raw == null) {
            return "";
        }
        String text = raw.trim();
        int brace = text.indexOf('{');
        if (brace > 0) {
            text = text.substring(brace);
        }
        int close = text.lastIndexOf('}');
        if (close >= 0 && close < text.length() - 1) {
            text = text.substring(0, close + 1);
        }
        JSONObject node;
        try {
            node = new JSONObject(text);
        } catch (Exception e) {
            return "";
        }
        String trans = node.optString("trans", "");
        if (trans.isEmpty()) {
            return "";
        }
        if (trans.indexOf('[') < 0) {
            try {
                byte[] decoded = android.util.Base64.decode(trans, android.util.Base64.DEFAULT);
                String plain = new String(decoded, "UTF-8");
                if (plain.indexOf('[') >= 0) {
                    trans = plain;
                }
            } catch (Exception ignored) {
            }
        }
        return unescapeHtml(trans);
    }

    // ------------------------------------------------------------------
    // lyrics.ovh（纯文本兜底）
    // ------------------------------------------------------------------

    /**
     * lyrics.ovh：只有纯文本、没有时间轴，但当另外几家全空时，
     * 用户勾了「接受纯文本歌词」至少还能拿到词。路径参数需要单独编码。
     */
    public static List<Hit> ovh(String title, String artist) {
        List<Hit> out = new ArrayList<Hit>();
        String t = safe(title);
        if (t.isEmpty()) {
            return out;
        }
        String a = safe(artist);
        if (a.isEmpty()) {
            a = "unknown";
        }
        String base = Endpoints.url("lyric_ovh", 0);
        if (base.endsWith("/")) {
            base = base.substring(0, base.length() - 1);
        }
        String url = base + "/" + encodePath(a) + "/" + encodePath(t);
        Object payload = Http.getJson(url, null, null, TIMEOUT_MS);
        if (!(payload instanceof JSONObject)) {
            return out;
        }
        String lyric = ((JSONObject) payload).optString("lyrics", "");
        if (lyric.trim().isEmpty()) {
            return out;
        }
        Hit h = new Hit();
        h.source = OVH;
        h.title = title;
        h.artist = artist;
        h.plain = lyric;
        out.add(h);
        return out;
    }

    // ------------------------------------------------------------------
    // 酷狗
    // ------------------------------------------------------------------

    /**
     * 酷狗：搜索候选 → 取歌词。
     *
     * <p>取词走两步：先要 {@code fmt=krc}（逐字），用 {@link com.dsh.musicorganizer.core.Krc}
     * 解出来就是增强型 LRC，行内带逐字时间；解不出来（线上样本多一层加密，见 Krc 类注释）
     * 就退回 {@code fmt=lrc} 的明文 LRC —— <b>降级是常态，不是异常</b>。
     *
     * <p>两个接口都是 http（酷狗的 https 证书在部分网络下校验失败），地址登记在
     * {@code Endpoints} 的 {@code lyric_kugou} 源，用户可改。
     */
    public static List<Hit> kugou(String title, String artist, Double duration) {
        List<Hit> out = new ArrayList<Hit>();
        String q = (safe(artist) + " " + safe(title)).trim();
        if (q.trim().isEmpty()) {
            return out;
        }
        Map<String, String> params = new HashMap<String, String>();
        params.put("ver", "1");
        params.put("man", "yes");
        params.put("client", "mobi");
        params.put("keyword", q);
        params.put("duration", duration != null && duration > 0
                ? String.valueOf(Math.round(duration * 1000)) : "");
        params.put("hash", "");
        JSONArray candidates = searchKugou(params);
        if (candidates == null) {
            // 「艺人 + 歌名」查不到时，酷狗偶尔只认歌名（关键词越长越容易空）
            params.put("keyword", safe(title));
            candidates = searchKugou(params);
        }
        if (candidates == null) {
            return out;
        }
        List<Pick> picks = new ArrayList<Pick>();
        for (int i = 0; i < candidates.length(); i++) {
            JSONObject c = candidates.optJSONObject(i);
            if (c == null) {
                continue;
            }
            Pick p = new Pick();
            p.node = c;
            p.title = c.optString("song", "");
            p.artist = c.optString("singer", "");
            long ms = c.optLong("duration", 0);
            if (ms > 0) {
                p.duration = ms / 1000.0;
            }
            p.order = i;
            p.score = roughScore(title, artist, duration, p.title, p.artist, p.duration);
            picks.add(p);
        }
        sortPicks(picks);

        int fetched = 0;
        for (Pick p : picks) {
            if (fetched >= MAX_LYRIC_FETCH) {
                break;
            }
            String id = p.node.optString("id", "");
            String accessKey = p.node.optString("accesskey", "");
            if (id.isEmpty() || accessKey.isEmpty()) {
                continue;
            }
            fetched++;
            String synced = fetchKugouLyric(id, accessKey, "krc");
            if (!synced.isEmpty()) {
                String plainKrc = com.dsh.musicorganizer.core.Krc.decode(synced);
                if (!plainKrc.trim().isEmpty()) {
                    String enhanced = com.dsh.musicorganizer.core.Krc.toEnhancedLrc(plainKrc);
                    if (!enhanced.isEmpty()) {
                        Hit h = new Hit();
                        h.source = KUGOU;
                        h.title = p.title;
                        h.artist = p.artist;
                        h.duration = p.duration;
                        h.synced = enhanced;
                        out.add(h);
                        continue;
                    }
                }
            }
            // 降级：要明文 LRC（KRC 仍未拿到的歌才走这里，实测稳定）
            String lrcBody = fetchKugouLyric(id, accessKey, "lrc");
            if (lrcBody.isEmpty()) {
                continue;
            }
            String text;
            if (lrcBody.trim().startsWith("[")) {
                // 服务端直接给了明文 LRC（不是 base64），别再解一次
                text = lrcBody;
            } else {
                byte[] bytes = com.dsh.musicorganizer.core.Krc.decodeBase64(lrcBody);
                if (bytes == null || bytes.length == 0) {
                    continue;
                }
                text = new String(bytes, java.nio.charset.StandardCharsets.UTF_8);
            }
            if (text.trim().isEmpty()) {
                continue;
            }
            Hit h = new Hit();
            h.source = KUGOU;
            h.title = p.title;
            h.artist = p.artist;
            h.duration = p.duration;
            h.synced = text;
            out.add(h);
        }
        return out;
    }

    /** 酷狗搜索：返回 candidates 数组，失败返回 null。 */
    private static JSONArray searchKugou(Map<String, String> params) {
        Object payload = Http.getJson(Endpoints.url("lyric_kugou", 0), params, null, TIMEOUT_MS);
        if (!(payload instanceof JSONObject)) {
            return null;
        }
        JSONArray arr = ((JSONObject) payload).optJSONArray("candidates");
        if (arr == null || arr.length() == 0) {
            return null;
        }
        return arr;
    }

    /**
     * 取酷狗歌词：返回服务端 {@code content} 的 base64 原文（krc 或 lrc，看 fmt）。
     * 失败返回空串 —— 酷狗失败时也返 200 + 空 content，不能只看 HTTP 状态。
     */
    private static String fetchKugouLyric(String id, String accessKey, String fmt) {
        Map<String, String> params = new HashMap<String, String>();
        params.put("ver", "1");
        params.put("client", "pc");
        params.put("id", id);
        params.put("accesskey", accessKey);
        params.put("fmt", fmt);
        params.put("charset", "utf8");
        Object payload = Http.getJson(Endpoints.url("lyric_kugou", 1), params, null, TIMEOUT_MS);
        if (!(payload instanceof JSONObject)) {
            return "";
        }
        return ((JSONObject) payload).optString("content", "");
    }

    // ------------------------------------------------------------------
    // 内部工具
    // ------------------------------------------------------------------

    /** 一条待取歌词的搜索结果。 */
    private static final class Pick {
        JSONObject node;
        String title = "";
        String artist = "";
        Double duration = null;
        double score = 0;
        int order = 0;
    }

    /** 粗排：只为决定「先取哪几条的歌词」，最终取舍在 core.Lyrics。 */
    private static double roughScore(String title, String artist, Double duration,
                                     String cTitle, String cArtist, Double cDur) {
        double ts = TextUtil.textSimilarity(safe(title), cTitle);
        double as;
        if (safe(artist).isEmpty() || cArtist == null || cArtist.isEmpty()) {
            as = 0.5;
        } else {
            as = TextUtil.bestArtistSimilarity(safe(artist), cArtist);
        }
        double ds;
        if (duration == null || duration <= 0 || cDur == null || cDur <= 0) {
            ds = 0.5;
        } else {
            double diff = Math.abs(duration - cDur);
            ds = diff <= 3 ? 1.0 : (diff >= 15 ? 0.0 : 1.0 - (diff - 3) / 12.0);
        }
        return 0.55 * ts + 0.25 * as + 0.20 * ds;
    }

    private static void sortPicks(List<Pick> picks) {
        Collections.sort(picks, new Comparator<Pick>() {
            @Override
            public int compare(Pick a, Pick b) {
                int x = Double.compare(b.score, a.score);
                return x != 0 ? x : Integer.compare(a.order, b.order);
            }
        });
    }

    private static String joinArtists(JSONArray array) {
        if (array == null) {
            return "";
        }
        List<String> names = new ArrayList<String>();
        for (int i = 0; i < array.length(); i++) {
            JSONObject a = array.optJSONObject(i);
            if (a != null) {
                names.add(a.optString("name", ""));
            }
        }
        return TextUtil.joinArtists(names, ",");
    }

    private static String encodePath(String text) {
        try {
            return java.net.URLEncoder.encode(text, "UTF-8").replace("+", "%20");
        } catch (Exception e) {
            return text;
        }
    }

    /** QQ 返回的歌词里偶有数字实体与 &apos; 之类，不转义会原样写进 .lrc。 */
    private static String unescapeHtml(String text) {
        if (text == null || text.indexOf('&') < 0) {
            return text == null ? "" : text;
        }
        return text.replace("&apos;", "'")
                .replace("&quot;", "\"")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&nbsp;", " ")
                .replace("&#39;", "'")
                .replace("&#58;", ":")
                .replace("&#46;", ".")
                .replace("&#45;", "-")
                .replace("&#44;", ",")
                .replace("&amp;", "&");
    }

    private static String safe(String s) {
        return s == null ? "" : s.trim();
    }
}
