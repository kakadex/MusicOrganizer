package com.dsh.musicorganizer.net;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * MusicBrainz 客户端 —— 对应 Python 版 MusicBrainzClient（限流 + 会话内缓存）。
 * 磁盘缓存在安卓版简化为内存缓存（进程生命周期），避免写共享存储。
 */
public final class MbClient {

    /** 默认地址（仅留档，实际请求一律走 {@link Endpoints}，用户可改）。 */
    public static final String ENDPOINT = "https://musicbrainz.org/ws/2/recording/";
    private static final long MIN_INTERVAL_MS = 1050;
    private static final int TIMEOUT_MS = 12000;

    private final Map<String, List<Map<String, Object>>> cache =
            new ConcurrentHashMap<String, List<Map<String, Object>>>();
    /** 下一次可发请求的时间戳（票制限流，官方要求 1 req/s）。 */
    private long nextSlot = 0;
    private volatile boolean offline = false;
    private final java.util.concurrent.atomic.AtomicInteger consecutiveErrors =
            new java.util.concurrent.atomic.AtomicInteger();
    private static final int CACHE_LIMIT = 512;

    /** 搜索录音；返回 {title, artist, album, date, score} 列表。 */
    public List<Map<String, Object>> searchRecordings(
            String title, String expectedArtist, int limit) {
        List<Map<String, Object>> out = new ArrayList<Map<String, Object>>();
        if (title == null || title.trim().isEmpty() || offline || limit <= 0) {
            return out;
        }
        String key = key(title, expectedArtist, limit);
        List<Map<String, Object>> cached = cache.get(key);
        if (cached != null) {
            return new ArrayList<Map<String, Object>>(cached);
        }
        throttle();
        Map<String, String> params = new HashMap<String, String>();
        String query = "recording:\"" + luceneEscape(title.trim()) + "\"";
        if (expectedArtist != null && !expectedArtist.trim().isEmpty()) {
            query += " AND artist:\"" + luceneEscape(expectedArtist.trim()) + "\"";
        }
        params.put("query", query);
        params.put("fmt", "json");
        params.put("limit", String.valueOf(Math.max(1, Math.min(limit, 20))));
        Object payload = Http.getJson(Endpoints.url("musicbrainz", 0), params, null, TIMEOUT_MS);
        if (!(payload instanceof JSONObject)) {
            if (consecutiveErrors.incrementAndGet() >= 3) {
                offline = true;
            }
            return out;
        }
        consecutiveErrors.set(0);
        // 成功一次就解除「离线锁」。以前这里只清计数不清 offline，
        // 网络抖动三次就把整场会话的 MusicBrainz 查询永久关掉（且日志里看不出来）。
        offline = false;
        JSONArray recordings = ((JSONObject) payload).optJSONArray("recordings");
        if (recordings != null) {
            for (int i = 0; i < recordings.length() && i < 20; i++) {
                JSONObject rec = recordings.optJSONObject(i);
                if (rec == null) {
                    continue;
                }
                Map<String, Object> hit = parseRecording(rec);
                if (hit != null) {
                    out.add(hit);
                }
            }
        }
        if (cache.size() > CACHE_LIMIT) {
            cache.clear();
        }
        cache.put(key, new ArrayList<Map<String, Object>>(out));
        return out;
    }

    public boolean isOffline() {
        return offline;
    }

    private static Map<String, Object> parseRecording(JSONObject rec) {
        String title = rec.optString("title", "").trim();
        String artist = joinArtistCredit(rec);
        if (title.isEmpty() || artist.isEmpty()) {
            return null;
        }
        String album = "";
        String date = rec.optString("first-release-date", "");
        JSONArray releases = rec.optJSONArray("releases");
        if (releases != null && releases.length() > 0) {
            JSONObject r0 = releases.optJSONObject(0);
            if (r0 != null) {
                album = r0.optString("title", "");
                if (date.isEmpty()) {
                    date = r0.optString("date", "");
                }
            }
        }
        Map<String, Object> hit = new HashMap<String, Object>();
        hit.put("title", title);
        hit.put("artist", artist);
        hit.put("album", album);
        hit.put("date", date);
        hit.put("score", rec.optInt("score", 0));
        return hit;
    }

    /** 从 artist-credit 严格取歌手名（R-01：歌名不可当歌手）。 */
    public static String joinArtistCredit(JSONObject node) {
        JSONArray credits = node.optJSONArray("artist-credit");
        if (credits == null || credits.length() == 0) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        List<String> names = new ArrayList<String>();
        for (int i = 0; i < credits.length(); i++) {
            JSONObject credit = credits.optJSONObject(i);
            if (credit == null) {
                continue;
            }
            String name = credit.optString("name", "");
            JSONObject artist = credit.optJSONObject("artist");
            if (name.isEmpty() && artist != null) {
                name = artist.optString("name", "");
            }
            if (name.isEmpty()) {
                continue;
            }
            names.add(name);
            sb.append(name);
            String join = credit.optString("joinphrase", "");
            sb.append(join);
        }
        if (sb.length() == 0 && !names.isEmpty()) {
            StringBuilder join = new StringBuilder();
            for (int i = 0; i < names.size(); i++) {
                if (i > 0) {
                    join.append(" & ");
                }
                join.append(names.get(i));
            }
            return join.toString();
        }
        return sb.toString().trim();
    }

    private static String luceneEscape(String text) {
        return text == null ? "" : text.replaceAll(
                "([+\\-!(){}\\[\\]^\"~*?:\\\\/])", "\\\\$1");
    }

    private static String key(String title, String artist, int limit) {
        return com.dsh.musicorganizer.core.TextUtil.normCompare(title)
                + "|" + com.dsh.musicorganizer.core.TextUtil.normCompare(artist == null ? "" : artist)
                + "|" + limit;
    }

    /** 票制限流：锁内只预约发车时间，锁外 sleep，避免把并发请求串成一条长队。 */
    private void throttle() {
        long wait;
        synchronized (this) {
            long now = System.currentTimeMillis();
            long slot = Math.max(now, nextSlot);
            nextSlot = slot + MIN_INTERVAL_MS;
            wait = slot - now;
        }
        if (wait > 0) {
            try {
                Thread.sleep(wait);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
}
