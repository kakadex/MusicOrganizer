package com.dsh.musicorganizer.net;

import com.dsh.musicorganizer.core.CancelToken;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.Zh;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 在线标签候选 —— 对应 Python 版 TagSource 系列与 SourceAggregator。
 *
 * 源：MusicBrainz（锚点）/ Deezer / iTunes（补充）/
 * 网易 / QQ / 酷狗 / 酷我 / 咪咕（中文召回）。
 * 全部走匿名只读接口，零 API Key（R-06）。
 *
 * <p><b>地址不写死</b>：一律经 {@link Endpoints#url(String, int)} 取，
 * 用户可在「数据源设置」里改域名或关掉某个源（接口挂掉时不用等发版）。
 */
public final class Sources {

    private Sources() {
    }

    private static final int TIMEOUT_MAIN = 8000;
    private static final int TIMEOUT_CN = 5000;
    public static final double DURATION_TOLERANCE = 3.0;

    /** 一次聚合最多返回多少条候选（去重后截断）。 */
    public static final int MAX_CANDIDATES = 10;

    public static class Candidate {
        public String title = "";
        public String artist = "";
        public String album = "";
        public String year = "";
        public String track = "";
        public String genre = "";
        public Double duration = null;
        public String source = "";
        /** 专辑封面地址（可能为空；封面补全功能用它，标签写入不关心） */
        public String coverUrl = "";
        public double confidence = 0;
        public double filenameScore = 0;
        /** 合并后命中几源（1 = 只有一家给出这条） */
        public int merged = 1;
        /** 合并后命中的来源，如「网易云 / QQ」 */
        public String sources = "";
    }

    /** 查询上下文。 */
    public static class Query {
        public List<String[]> filenameCandidates = new ArrayList<String[]>();
        public Map<String, String> embeddedTags = new HashMap<String, String>();
        public Double localDuration = null;
        public boolean useCnSources = true;
        /** 文件名权重 0~1：越高越信文件名解析结果，越低越信已有标签。 */
        public double filenameWeight = com.dsh.musicorganizer.core.NameWeight
                .fromPercent(com.dsh.musicorganizer.core.NameWeight.DEFAULT_PERCENT);
    }

    // ------------------------------------------------------------------
    // 各数据源
    // ------------------------------------------------------------------

    private static String[] firstPair(Query ctx) {
        if (!ctx.filenameCandidates.isEmpty()) {
            return ctx.filenameCandidates.get(0);
        }
        return new String[]{"", ""};
    }

    /**
     * 参与检索的歌名：按文件名权重在「文件名解析结果」与「已有标签」之间取舍。
     * 权重 < 50% 优先标签（文件名兜底），>= 50% 优先文件名（标签兜底）。
     */
    private static String pickTitle(Query ctx) {
        String[] p = firstPair(ctx);
        String fromName = p[1].trim();
        String fromTag = ctx.embeddedTags.get("title") == null ? "" : ctx.embeddedTags.get("title");
        return com.dsh.musicorganizer.core.NameWeight
                .pick(fromName, fromTag, ctx.filenameWeight);
    }

    /** 参与检索的歌手：取舍规则同 {@link #pickTitle}。 */
    private static String pickArtist(Query ctx) {
        String[] p = firstPair(ctx);
        String fromName = p[0].trim();
        String fromTag = ctx.embeddedTags.get("artist") == null ? "" : ctx.embeddedTags.get("artist");
        return com.dsh.musicorganizer.core.NameWeight
                .pick(fromName, fromTag, ctx.filenameWeight);
    }

    /** 文本是否「像中文曲目」：含汉字且不像日文（日文假名优先判定）。 */
    private static boolean hasHan(String s) {
        if (s == null || s.isEmpty()) {
            return false;
        }
        return TextUtil.containsChinese(s) && !Zh.isJapanese(s);
    }

    /** 这次查询的曲目是否中文（标题或艺人任一方含汉字且非日文）。 */
    private static boolean isChineseTrack(Query ctx) {
        return hasHan(pickTitle(ctx)) || hasHan(pickArtist(ctx));
    }

    public static List<Candidate> musicBrainz(MbClient client, Query ctx) {
        List<Candidate> out = new ArrayList<Candidate>();
        if (client.isOffline()) {
            return out;
        }
        String title = pickTitle(ctx);
        String artist = pickArtist(ctx);
        if (title.isEmpty() && artist.isEmpty()) {
            return out;
        }
        List<Map<String, Object>> hits = client.searchRecordings(title, artist, 8);
        if (hits.isEmpty()) {
            return out;
        }
        for (Map<String, Object> hit : hits) {
            Candidate c = new Candidate();
            c.title = String.valueOf(hit.get("title"));
            c.artist = String.valueOf(hit.get("artist"));
            c.album = String.valueOf(hit.get("album"));
            String date = String.valueOf(hit.get("date"));
            c.year = date.length() >= 4 ? date.substring(0, 4) : "";
            c.source = "musicbrainz";
            c.confidence = 0.85;
            out.add(c);
        }
        return out;
    }

    public static List<Candidate> deezer(Query ctx) {
        List<Candidate> out = new ArrayList<Candidate>();
        String q = (pickArtist(ctx) + " " + pickTitle(ctx)).trim();
        if (q.isEmpty()) {
            return out;
        }
        Map<String, String> params = new HashMap<String, String>();
        params.put("q", q);
        params.put("limit", "5");
        Object payload = Http.getJson(Endpoints.url("deezer", 0), params, null, TIMEOUT_MAIN);
        if (!(payload instanceof JSONObject)) {
            return out;
        }
        JSONArray data = ((JSONObject) payload).optJSONArray("data");
        if (data == null) {
            return out;
        }
        for (int i = 0; i < data.length(); i++) {
            JSONObject t = data.optJSONObject(i);
            if (t == null) {
                continue;
            }
            Candidate c = new Candidate();
            c.title = t.optString("title", "");
            JSONObject artist = t.optJSONObject("artist");
            c.artist = artist == null ? "" : artist.optString("name", "");
            JSONObject album = t.optJSONObject("album");
            c.album = album == null ? "" : album.optString("title", "");
            if (album != null) {
                c.coverUrl = firstNonEmpty(album.optString("cover_xl", ""),
                        album.optString("cover_big", ""));
            }
            long dur = t.optLong("duration", 0);
            if (dur > 0) {
                c.duration = (double) dur;
            }
            c.source = "deezer";
            c.confidence = 0.75;
            out.add(c);
        }
        return out;
    }

    public static List<Candidate> iTunes(Query ctx) {
        List<Candidate> out = new ArrayList<Candidate>();
        String term = (pickArtist(ctx) + " " + pickTitle(ctx)).trim();
        if (term.isEmpty()) {
            return out;
        }
        Map<String, String> params = new HashMap<String, String>();
        params.put("term", term);
        params.put("media", "music");
        params.put("limit", "5");
        Object payload = Http.getJson(Endpoints.url("itunes", 0), params, null, TIMEOUT_MAIN);
        if (!(payload instanceof JSONObject)) {
            return out;
        }
        JSONArray results = ((JSONObject) payload).optJSONArray("results");
        if (results == null) {
            return out;
        }
        for (int i = 0; i < results.length(); i++) {
            JSONObject t = results.optJSONObject(i);
            if (t == null) {
                continue;
            }
            Candidate c = new Candidate();
            c.title = t.optString("trackName", "");
            c.artist = t.optString("artistName", "");
            c.album = t.optString("collectionName", "");
            c.year = t.optString("releaseDate", "");
            if (c.year.length() >= 4) {
                c.year = c.year.substring(0, 4);
            } else {
                c.year = "";
            }
            long ms = t.optLong("trackTimeMillis", 0);
            if (ms > 0) {
                c.duration = ms / 1000.0;
            }
            c.coverUrl = itunesCover(t.optString("artworkUrl100", ""));
            c.source = "itunes";
            c.confidence = 0.75;
            out.add(c);
        }
        return out;
    }

    /** iTunes 的 artworkUrl100 只有 100×100，换成 600×600（尺寸段是路径里的 100x100）。 */
    static String itunesCover(String artworkUrl100) {
        if (artworkUrl100 == null || artworkUrl100.isEmpty()) {
            return "";
        }
        return artworkUrl100.replace("/100x100bb", "/600x600bb")
                .replace("100x100bb", "600x600bb");
    }

    private static String firstNonEmpty(String a, String b) {
        return a != null && !a.isEmpty() ? a : (b == null ? "" : b);
    }

    private interface SourceCall {
        List<Candidate> run();
    }

    // ------------------------------------------------------------------
    // 软冷却：某些站「HTTP 200 但 body 里告诉你被限流」
    // ------------------------------------------------------------------

    /** 源 → 冷却截止时间戳。限流后短暂跳过，别让每首歌都白跑一遍。 */
    private static final Map<String, Long> SOFT_COOLDOWN =
            new java.util.concurrent.ConcurrentHashMap<String, Long>();

    private static boolean cooling(String source) {
        Long until = SOFT_COOLDOWN.get(source);
        return until != null && until > System.currentTimeMillis();
    }

    private static void coolDown(String source, long ms) {
        SOFT_COOLDOWN.put(source, System.currentTimeMillis() + ms);
    }

    public static List<Candidate> netease(Query ctx) {
        SourceCall call = new SourceCall() {
            @Override
            public List<Candidate> run() {
                List<Candidate> out = new ArrayList<Candidate>();
                if (cooling("netease")) {
                    return out;
                }
                String q = (pickArtist(ctx) + " " + pickTitle(ctx)).trim();
                if (q.isEmpty()) {
                    return out;
                }
                Map<String, String> params = new HashMap<String, String>();
                params.put("s", q);
                params.put("type", "1");
                params.put("offset", "0");
                params.put("limit", "5");
                Map<String, String> headers = new HashMap<String, String>();
                // Referer 是「这家站要求的来源页」，与接口地址是两回事：
                // 换地址（镜像/代理）时它一般仍需保持原站，所以不做成可配置项
                headers.put("Referer", "https://music.163.com/");
                // 网易云对匿名调用有频率限制，带上 appver 才稳定；
                // 老地址 /api/search/get/web 现在直接返 405「操作频繁」，不能用
                headers.put("Cookie", "appver=2.0.2");
                Object payload = Http.getJson(Endpoints.url("netease", 0),
                        params, headers, TIMEOUT_CN);
                if (!(payload instanceof JSONObject)) {
                    return out;
                }
                JSONObject result = ((JSONObject) payload).optJSONObject("result");
                if (result == null) {
                    // code 405 = 操作频繁：冷却 60 秒，免得后面每首都去撞墙
                    if (((JSONObject) payload).optInt("code", 0) == 405) {
                        coolDown("netease", 60000L);
                    }
                    return out;
                }
                JSONArray songs = result.optJSONArray("songs");
                if (songs == null) {
                    return out;
                }
                for (int i = 0; i < songs.length(); i++) {
                    JSONObject s = songs.optJSONObject(i);
                    if (s == null) {
                        continue;
                    }
                    Candidate c = new Candidate();
                    c.title = s.optString("name", "");
                    JSONArray artists = s.optJSONArray("artists");
                    List<String> names = new ArrayList<String>();
                    if (artists != null) {
                        for (int j = 0; j < artists.length(); j++) {
                            JSONObject a = artists.optJSONObject(j);
                            if (a != null) {
                                names.add(a.optString("name", ""));
                            }
                        }
                    }
                    c.artist = TextUtil.joinArtists(names, ",");
                    JSONObject album = s.optJSONObject("album");
                    c.album = album == null ? "" : album.optString("name", "");
                    // 年份：album.publishTime 是毫秒时间戳。境外源大多能给年份，
                    // 中文曲目以前只能靠 MusicBrainz（很多中文歌它根本没有），这里补上。
                    if (album != null) {
                        c.year = yearOfMillis(album.optLong("publishTime", 0));
                        String pic = album.optString("picUrl", "");
                        if (!pic.isEmpty()) {
                            c.coverUrl = pic + (pic.indexOf('?') >= 0 ? "&" : "?")
                                    + "param=800y800";
                        }
                    }
                    long dur = s.optLong("duration", 0);
                    if (dur > 0) {
                        c.duration = dur / 1000.0;
                    }
                    c.source = "netease";
                    c.confidence = 0.60;
                    out.add(c);
                }
                return out;
            }
        };
        return safeRun(call);
    }

    public static List<Candidate> qqMusic(Query ctx) {
        SourceCall call = new SourceCall() {
            @Override
            public List<Candidate> run() {
                List<Candidate> out = new ArrayList<Candidate>();
                if (cooling("qqmusic")) {
                    return out;
                }
                String q = (pickArtist(ctx) + " " + pickTitle(ctx)).trim();
                if (q.isEmpty()) {
                    return out;
                }
                Map<String, String> params = new HashMap<String, String>();
                // 旧接口 c.y.qq.com/soso/fcgi-bin/client_search_cp 现在已经返 500，
                // 换成网页版用的 musicu.fcg（同一个 data 包，只是要自己拼 JSON）
                JSONObject inner = new JSONObject();
                JSONObject comm = new JSONObject();
                JSONObject req = new JSONObject();
                JSONObject root = new JSONObject();
                try {
                    inner.put("num_per_page", 5);
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
                Object payload = Http.getJson(Endpoints.url("qqmusic", 0),
                        params, headers, TIMEOUT_CN);
                if (!(payload instanceof JSONObject)) {
                    return out;
                }
                JSONObject reqNode = ((JSONObject) payload).optJSONObject("req");
                int reqCode = reqNode == null ? 0 : reqNode.optInt("code", 0);
                JSONObject data = reqNode == null ? null : reqNode.optJSONObject("data");
                JSONObject body = data == null ? null : data.optJSONObject("body");
                JSONObject song = body == null ? null : body.optJSONObject("song");
                if (song == null) {
                    if (reqCode != 0) {
                        // 2001 = 请求过于频繁（而且回的是 HTTP 200，Http 层看不到）
                        coolDown("qqmusic", 60000L);
                    }
                    return out;
                }
                JSONArray list = song.optJSONArray("list");
                if (list == null || (list.length() == 0 && reqCode != 0)) {
                    if (reqCode != 0) {
                        coolDown("qqmusic", 60000L);
                    }
                    return out;
                }
                for (int i = 0; i < list.length(); i++) {
                    JSONObject s = list.optJSONObject(i);
                    if (s == null) {
                        continue;
                    }
                    Candidate c = new Candidate();
                    c.title = s.optString("name", s.optString("title", ""));
                    JSONArray singers = s.optJSONArray("singer");
                    List<String> names = new ArrayList<String>();
                    if (singers != null) {
                        for (int j = 0; j < singers.length(); j++) {
                            JSONObject a = singers.optJSONObject(j);
                            if (a != null) {
                                names.add(a.optString("name", ""));
                            }
                        }
                    }
                    c.artist = TextUtil.joinArtists(names, ",");
                    JSONObject album = s.optJSONObject("album");
                    c.album = album == null ? "" : album.optString("name", "");
                    if (album != null) {
                        String mid = album.optString("mid", album.optString("albummid", ""));
                        if (!mid.isEmpty()) {
                            // 封面要用 albummid 拼；用 songmid 会 404
                            c.coverUrl = "https://y.gtimg.cn/music/photo_new/T002R800x800M000"
                                    + mid + ".jpg";
                        }
                    }
                    // 发行日期 time_public = "2003-07-31"，取前 4 位当年份
                    String pub = s.optString("time_public", "");
                    if (pub.length() >= 4) {
                        c.year = pub.substring(0, 4);
                    }
                    // index_album 就是专辑内曲序号，中文曲目的「音轨」字段多来自这里
                    int idx = s.optInt("index_album", 0);
                    if (idx > 0) {
                        c.track = String.valueOf(idx);
                    }
                    long dur = s.optLong("interval", 0);
                    if (dur > 0) {
                        c.duration = (double) dur;
                    }
                    c.source = "qqmusic";
                    c.confidence = 0.60;
                    out.add(c);
                }
                return out;
            }
        };
        return safeRun(call);
    }

    public static List<Candidate> kugou(Query ctx) {
        SourceCall call = new SourceCall() {
            @Override
            public List<Candidate> run() {
                List<Candidate> out = new ArrayList<Candidate>();
                String q = (pickArtist(ctx) + " " + pickTitle(ctx)).trim();
                if (q.isEmpty()) {
                    return out;
                }
                Map<String, String> params = new HashMap<String, String>();
                params.put("keyword", q);
                params.put("page", "1");
                params.put("pagesize", "5");
                params.put("format", "json");
                Object payload = Http.getJson(Endpoints.url("kugou", 0),
                        params, null, TIMEOUT_CN);
                if (!(payload instanceof JSONObject)) {
                    return out;
                }
                JSONObject data = ((JSONObject) payload).optJSONObject("data");
                if (data == null) {
                    return out;
                }
                JSONArray info = data.optJSONArray("info");
                if (info == null) {
                    return out;
                }
                for (int i = 0; i < info.length(); i++) {
                    JSONObject s = info.optJSONObject(i);
                    if (s == null) {
                        continue;
                    }
                    Candidate c = new Candidate();
                    c.title = s.optString("songname", "");
                    c.artist = s.optString("singername", "");
                    c.album = s.optString("album_name", "");
                    long dur = s.optLong("duration", 0);
                    if (dur > 0) {
                        c.duration = (double) dur;
                    }
                    c.source = "kugou";
                    c.confidence = 0.60;
                    out.add(c);
                }
                return out;
            }
        };
        return safeRun(call);
    }

    public static List<Candidate> migu(Query ctx) {
        SourceCall call = new SourceCall() {
            @Override
            public List<Candidate> run() {
                List<Candidate> out = new ArrayList<Candidate>();
                String q = (pickArtist(ctx) + " " + pickTitle(ctx)).trim();
                if (q.isEmpty()) {
                    return out;
                }
                Map<String, String> params = new HashMap<String, String>();
                // 咪咕网页版（m.music.migu.cn/migu/remoting/scr_search_tag）已经下线，
                // 现在只返回一个 SPA 壳；改用它 App 端仍在用的 search_all.do
                params.put("text", q);
                params.put("pageNo", "1");
                params.put("pageSize", "5");
                params.put("isCopyright", "1");
                params.put("sort", "1");
                params.put("searchSwitch",
                        "{\"song\":1,\"album\":0,\"singer\":0,\"tagSong\":1,\"mvSong\":0,"
                                + "\"bestShow\":1,\"songlist\":0,\"lyricSong\":0}");
                Map<String, String> headers = new HashMap<String, String>();
                headers.put("Referer", "https://app.c.nf.migu.cn/");
                Object payload = Http.getJson(Endpoints.url("migu", 0),
                        params, headers, TIMEOUT_CN);
                if (!(payload instanceof JSONObject)) {
                    return out;
                }
                JSONObject resultData = ((JSONObject) payload).optJSONObject("songResultData");
                if (resultData == null) {
                    return out;
                }
                JSONArray musics = resultData.optJSONArray("result");
                if (musics == null) {
                    return out;
                }
                // 咪咕会忽略 pageSize 直接回 20 条，这里自己截断，减少后面的打分开销
                int taken = 0;
                for (int i = 0; i < musics.length() && taken < 6; i++) {
                    JSONObject s = musics.optJSONObject(i);
                    if (s == null) {
                        continue;
                    }
                    // 结果里可能混着歌单/专辑，只留 resourceType=2（单曲）
                    String type = s.optString("resourceType", "");
                    if (!type.isEmpty() && !"2".equals(type)) {
                        continue;
                    }
                    Candidate c = new Candidate();
                    c.title = s.optString("name", "");
                    c.artist = joinNames(s.optJSONArray("singers"));
                    JSONArray albums = s.optJSONArray("albums");
                    if (albums != null && albums.length() > 0) {
                        JSONObject album = albums.optJSONObject(0);
                        c.album = album == null ? "" : album.optString("name", "");
                    }
                    // 咪咕的 tags 里混着地区/场景词，只认明确的流派词，避免写出「抖音」这种
                    c.genre = pickGenre(s.optJSONArray("tags"));
                    c.source = "migu";
                    c.confidence = 0.60;
                    out.add(c);
                    taken++;
                }
                return out;
            }
        };
        return safeRun(call);
    }

    /**
     * 酷我：中文曲库（尤其老歌、网络歌曲）覆盖比境外源强得多，
     * 是这轮新增的召回源；接口是 App 端在用的 r.s。
     */
    public static List<Candidate> kuwo(Query ctx) {
        SourceCall call = new SourceCall() {
            @Override
            public List<Candidate> run() {
                List<Candidate> out = new ArrayList<Candidate>();
                String q = (pickArtist(ctx) + " " + pickTitle(ctx)).trim();
                if (q.isEmpty()) {
                    return out;
                }
                Map<String, String> params = new HashMap<String, String>();
                params.put("client", "kt");
                params.put("all", q);
                params.put("pn", "0");
                params.put("rn", "5");
                params.put("uid", "1234");
                params.put("ver", "kwplayer_ar_9.2.2.1");
                params.put("vipver", "1");
                params.put("show_copyright_off", "1");
                params.put("newver", "1");
                params.put("ft", "music");
                params.put("cluster", "0");
                params.put("strategy", "2012");
                params.put("encoding", "utf8");
                params.put("rformat", "json");
                params.put("vermerge", "1");
                params.put("mobi", "1");
                Object payload = Http.getJson(Endpoints.url("kuwo", 0),
                        params, null, TIMEOUT_CN);
                if (!(payload instanceof JSONObject)) {
                    return out;
                }
                JSONArray list = ((JSONObject) payload).optJSONArray("abslist");
                if (list == null) {
                    return out;
                }
                for (int i = 0; i < list.length(); i++) {
                    JSONObject s = list.optJSONObject(i);
                    if (s == null) {
                        continue;
                    }
                    Candidate c = new Candidate();
                    c.title = s.optString("SONGNAME", s.optString("NAME", ""));
                    c.artist = s.optString("ARTIST", "");
                    c.album = s.optString("ALBUM", "");
                    long dur = s.optLong("DURATION", 0);
                    if (dur > 0) {
                        c.duration = (double) dur;
                    }
                    if (c.title.isEmpty()) {
                        continue;
                    }
                    c.source = "kuwo";
                    c.confidence = 0.60;
                    out.add(c);
                }
                return out;
            }
        };
        return safeRun(call);
    }

    private static List<Candidate> safeRun(SourceCall call) {
        try {
            return call.run();
        } catch (Exception e) {
            return new ArrayList<Candidate>();
        }
    }

    // ------------------------------------------------------------------
    // 解析小工具
    // ------------------------------------------------------------------

    /** [{"name":"周杰伦"}] → "周杰伦"。 */
    private static String joinNames(JSONArray array) {
        if (array == null) {
            return "";
        }
        List<String> names = new ArrayList<String>();
        for (int i = 0; i < array.length(); i++) {
            JSONObject a = array.optJSONObject(i);
            if (a != null) {
                String name = a.optString("name", "");
                if (!name.isEmpty()) {
                    names.add(name);
                }
            }
        }
        return TextUtil.joinArtists(names, ",");
    }

    /** 毫秒时间戳 → 四位年份；0 或异常值返回空串。 */
    private static String yearOfMillis(long millis) {
        if (millis <= 0) {
            return "";
        }
        java.util.Calendar c = java.util.Calendar.getInstance(
                java.util.TimeZone.getTimeZone("UTC"));
        c.setTimeInMillis(millis);
        int year = c.get(java.util.Calendar.YEAR);
        return year >= 1900 && year <= 2200 ? String.valueOf(year) : "";
    }

    /** 只认明确的流派词；地区/场景标签（抖音、中国台湾、KTV 金曲）一概不要。 */
    private static final String[] GENRE_WORDS = {
            "流行", "摇滚", "民谣", "电子", "说唱", "嘻哈", "爵士", "古典", "乡村",
            "金属", "朋克", "灵魂乐", "蓝调", "雷鬼", "舞曲", "轻音乐", "古风",
            "R&B", "R&B/Soul", "世界音乐", "原声", "动漫", "二次元",
    };

    private static String pickGenre(JSONArray tags) {
        if (tags == null || tags.length() == 0) {
            return "";
        }
        for (int i = 0; i < tags.length(); i++) {
            String tag = tags.optString(i, "").trim();
            if (tag.isEmpty()) {
                continue;
            }
            for (String word : GENRE_WORDS) {
                if (tag.equals(word)) {
                    return tag;
                }
            }
        }
        return "";
    }

    // ------------------------------------------------------------------
    // 聚合：时长交叉验证 + 置信度上限 + 文件名相似度混合
    // ------------------------------------------------------------------

    private static String sourceLabel(String source) {
        if ("musicbrainz".equals(source)) {
            return "MusicBrainz";
        } else if ("deezer".equals(source)) {
            return "Deezer";
        } else if ("itunes".equals(source)) {
            return "iTunes";
        } else if ("netease".equals(source)) {
            return "网易云";
        } else if ("qqmusic".equals(source)) {
            return "QQ 音乐";
        } else if ("kugou".equals(source)) {
            return "酷狗";
        } else if ("kuwo".equals(source)) {
            return "酷我";
        } else if ("migu".equals(source)) {
            return "咪咕";
        }
        return source;
    }

    /** 分发到具体数据源。 */
    /** 单源分派：走注册表（新增源只要在 {@link SourceRegistry} 登记，这里不用改）。 */
    private static List<Candidate> query(MbClient client, Query ctx, String source) {
        OnlineSource s = SourceRegistry.get(source);
        if (s == null) {
            return new ArrayList<Candidate>();
        }
        try {
            return s.search(ctx, client);
        } catch (Exception e) {
            // 单源异常只是少一家结果，聚合层本来也按「空结果」处理
            return new ArrayList<Candidate>();
        }
    }

    /** 一个源的返回结果，用于并发收集（需要知道是哪一家返回了多少条）。 */
    private static final class SourceResult {
        final String source;
        final List<Candidate> items;

        SourceResult(String source, List<Candidate> items) {
            this.source = source;
            this.items = items;
        }
    }

    // 源优先级、国内源判定与候选排序统一在 core.SourceRank 里（纯 Java，可进桌面回归）。
    // 这里只做转发，避免两套顺序表各改一半。

    /** 源优先级；未登记的源排最后。 */
    public static int sourcePriority(String source) {
        return com.dsh.musicorganizer.core.SourceRank.priority(source);
    }

    /** 是否国内源（网易 / QQ / 酷狗 / 酷我 / 咪咕）。 */
    public static boolean isChineseSource(String source) {
        return com.dsh.musicorganizer.core.SourceRank.isChinese(source);
    }

    /** 候选排序：置信度优先，中文曲目下国内源靠前、外文曲目下海外源靠前。 */
    public static int rank(Candidate a, Candidate b, boolean chinese) {
        return com.dsh.musicorganizer.core.SourceRank.compare(
                a.source, a.confidence, b.source, b.confidence, chinese);
    }

    /** @deprecated 请用 {@link #rank(Candidate, Candidate, boolean)} 并显式传入曲目语种。 */
    @Deprecated
    public static int rank(Candidate a, Candidate b) {
        return rank(a, b, true);
    }

    public static List<Candidate> aggregate(MbClient client, Query ctx) {
        return aggregate(client, ctx, null, null);
    }

    /**
     * 多源聚合；progress/cancel 可为 null。
     *
     * <p><b>源级并发</b>：七个源同时发出请求，总耗时从「各源之和」降到「最慢那个源」。
     * 老实现一个源一个源串行查，网络差时一首歌就要等好几个超时。
     * 每个源查完上报一次进度，进度条按「已完成源数 / 总源数」前进。
     */
    public static List<Candidate> aggregate(MbClient client, Query ctx,
                                            com.dsh.musicorganizer.core.Progress progress,
                                            CancelToken cancel) {
        // 参与并发的源：按 SOURCE_ORDER 的顺序收集（国内源先入列），
        // 国内源受「启用国内召回源」总开关控制，
        // 单个源还能在「数据源设置」里单独关掉（某家接口挂了就不必陪它等超时）
        // 中文曲目优先国内源顺序（国内在前），外文曲目优先海外源顺序（海外在前）。
        boolean chinese = isChineseTrack(ctx);
        List<String> chosen = new ArrayList<String>();
        for (String s : com.dsh.musicorganizer.core.SourceRank.order(chinese)) {
            if (isChineseSource(s) && !ctx.useCnSources) {
                continue;
            }
            if (Endpoints.enabled(s)) {
                chosen.add(s);
            }
        }
        if (chosen.isEmpty()) {
            return new ArrayList<Candidate>();
        }
        final String[] names = chosen.toArray(new String[chosen.size()]);
        final int total = names.length;
        final java.util.concurrent.atomic.AtomicInteger finished =
                new java.util.concurrent.atomic.AtomicInteger();

        List<java.util.concurrent.Callable<SourceResult>> tasks =
                new ArrayList<java.util.concurrent.Callable<SourceResult>>(total);
        for (final String source : names) {
            tasks.add(new java.util.concurrent.Callable<SourceResult>() {
                @Override
                public SourceResult call() {
                    List<Candidate> found = new ArrayList<Candidate>();
                    if (cancel == null || !cancel.isCancelled()) {
                        try {
                            found = query(client, ctx, source);
                        } catch (Exception ignored) {
                            // 单源异常只是少一家的结果
                        }
                    }
                    int d = finished.incrementAndGet();
                    if (progress != null) {
                        progress.onProgress(d, total, sourceLabel(source)
                                + " 返回 " + found.size() + " 条候选");
                    }
                    return new SourceResult(source, found);
                }
            });
        }

        List<Candidate> results = new ArrayList<Candidate>();
        for (SourceResult part : Net.gather(tasks, Net.sourceBudgetMs(), cancel)) {
            if (part != null && part.items != null) {
                results.addAll(part.items);
            }
        }
        if (progress != null) {
            progress.onProgress(total, total, "正在按时长与文件名相似度排序…");
        }

        if (ctx.localDuration != null && ctx.localDuration > 0) {
            List<Candidate> filtered = new ArrayList<Candidate>();
            for (Candidate c : results) {
                if (c.duration == null
                        || Math.abs(c.duration - ctx.localDuration) <= DURATION_TOLERANCE) {
                    filtered.add(c);
                }
            }
            if (!filtered.isEmpty()) {
                results = filtered;
            }
        }

        boolean mb = false;
        boolean dz = false;
        boolean it = false;
        // 国内源「家数」而不是候选条数：一家返回 5 条也只算一家，
        // 老实现把条数当家数用，一条国内结果就能冒充「两家一致」
        Set<String> cnSet = new HashSet<String>();
        for (Candidate c : results) {
            if (c.source.equals("musicbrainz")) {
                mb = true;
            } else if (c.source.equals("deezer")) {
                dz = true;
            } else if (c.source.equals("itunes")) {
                it = true;
            } else if (isChineseSource(c.source)) {
                cnSet.add(c.source);
            }
        }
        int cnSources = cnSet.size();

        // 置信度上限：多源互相印证才敢给高分。
        // v0.1.44 上调国内源 —— 原来「国内源 ≥2 家」只能到 0.80，而 MusicBrainz + Deezer
        // 能到 1.00，等于系统性地把中文歌的国内结果压在海外结果下面。
        double cap;
        if (cnSources >= 2 || (cnSources >= 1 && mb) || (mb && dz)) {
            cap = 1.00;
        } else if (cnSources == 1) {
            cap = 0.92;
        } else if (mb) {
            cap = 0.85;
        } else if (dz || it) {
            cap = 0.75;
        } else {
            cap = 0.60;
        }

        for (Candidate c : results) {
            double score = filenameSimilarity(ctx.filenameCandidates, c.title, c.artist);
            if (score >= 0) {
                c.filenameScore = score;
            }
            double blended;
            if (score >= 0) {
                blended = Math.min(c.confidence, cap) * (1.0 - ctx.filenameWeight)
                        + score * ctx.filenameWeight;
            } else {
                blended = Math.min(c.confidence, cap);
            }
            c.confidence = Math.min(cap, blended);
        }
        // 多源去重：同一首歌在几家都返回时只留一条（保留最高分），并记下「几源一致」。
        // 放在打分之后 —— 代表条目必须是最高的那条，否则排序会把次优结果顶到最前面。
        results = dedupe(results);
        if (results.size() > MAX_CANDIDATES) {
            // 预览面板最多展示这么多条：再多用户也不会往下翻，反而拖慢渲染
            results = new ArrayList<Candidate>(results.subList(0, MAX_CANDIDATES));
        }
        java.util.Collections.sort(results, new java.util.Comparator<Candidate>() {
            @Override
            public int compare(Candidate a, Candidate b) {
                // 置信度为主，中文曲目下国内源优先、外文曲目下海外源优先（见 rank 的注释）
                return rank(a, b, chinese);
            }
        });
        return results;
    }

    /**
     * 把同一首歌的候选合并成一条（v0.1.80）。
     *
     * <p>判同规则见 {@link com.dsh.musicorganizer.core.MatchDedupe}（标题 + 艺人 + 时长容差）。
     * 合并后 {@code merged} 是命中源数，{@code sources} 是来源串 —— 多源一致本身是可信度信号，
     * 预览里可以据此让用户更放心。
     */
    static List<Candidate> dedupe(List<Candidate> in) {
        if (in == null || in.size() < 2) {
            return in;
        }
        List<com.dsh.musicorganizer.core.MatchDedupe.Entry> entries =
                new ArrayList<com.dsh.musicorganizer.core.MatchDedupe.Entry>(in.size());
        for (Candidate c : in) {
            if (c == null) {
                continue;
            }
            com.dsh.musicorganizer.core.MatchDedupe.Entry e =
                    new com.dsh.musicorganizer.core.MatchDedupe.Entry();
            e.title = c.title;
            e.artist = c.artist;
            e.duration = c.duration;
            e.score = c.confidence;
            e.source = sourceLabel(c.source);
            e.payload = c;
            entries.add(e);
        }
        List<Candidate> out = new ArrayList<Candidate>(entries.size());
        for (com.dsh.musicorganizer.core.MatchDedupe.Entry g
                : com.dsh.musicorganizer.core.MatchDedupe.merge(entries)) {
            Candidate c = (Candidate) g.payload;
            c.merged = g.merged;
            c.sources = g.sources;
            out.add(c);
        }
        return out;
    }

    /**
     * 取封面图需要的请求头。
     *
     * <p>QQ 音乐与网易的图床都校验 Referer：不带就回 403，预览里会变成一片空白
     * （而不是「下载失败」，容易误判成没有封面）。批量补封面与候选卡片预览共用这一份，
     * 免得两处规则走偏。
     */
    public static Map<String, String> coverHeaders(String url) {
        Map<String, String> headers = new java.util.HashMap<String, String>();
        String u = url == null ? "" : url;
        if (u.contains("gtimg.cn")) {
            headers.put("Referer", "https://y.qq.com/");
        } else if (u.contains("126.net") || u.contains("music.163.com")) {
            headers.put("Referer", "https://music.163.com/");
        }
        return headers;
    }

    /**
     * 候选与文件名解析结果的相似度（标题 70% + 艺术家 30%）。
     * 没有文件名线索返回 -1。
     */
    public static double filenameSimilarity(List<String[]> candidates,
                                            String title, String artist) {
        double best = -1;
        for (String[] pair : candidates) {
            String fArtist = pair[0] == null ? "" : pair[0].trim();
            String fTitle = pair[1] == null ? "" : pair[1].trim();
            if (fTitle.isEmpty()) {
                continue;
            }
            double titleSim = TextUtil.textSimilarity(fTitle, title);
            double score;
            if (!fArtist.isEmpty() && artist != null && !artist.isEmpty()) {
                double artistSim = TextUtil.bestArtistSimilarity(fArtist, artist);
                score = 0.70 * titleSim + 0.30 * artistSim;
            } else {
                score = titleSim;
            }
            if (fArtist.isEmpty() && score < 0.5) {
                continue;
            }
            if (score > best) {
                best = Math.max(0.0, Math.min(1.0, score));
            }
        }
        return best;
    }
}
