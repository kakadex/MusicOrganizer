package com.dsh.musicorganizer.net;

import com.dsh.musicorganizer.core.TextUtil;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * LRCLIB 歌词客户端 —— 对应 Python 版 LrcLibClient。
 * 精确 /api/get 优先，失败回退 /api/search；无鉴权、限流 350ms。
 *
 * <p>并发说明（批量歌词会多线程同时调 {@link #lookup}）：
 * <ul>
 *   <li>缓存用 ConcurrentHashMap，并有容量上限，长批量不会把内存吃穿；</li>
 *   <li>限流改成「取号」：锁内只算下一次可用时间，锁外 sleep，
 *       多线程按 350ms 均匀发出，而不是排队等「上一次请求 + 350ms」；</li>
 *   <li>失败原因改 ThreadLocal，避免并发时互相覆盖。</li>
 * </ul>
 */
public final class LrcClient {

    /** 默认地址（仅留档，实际请求一律走 {@link Endpoints}，用户可改）。 */
    private static final String GET_ENDPOINT = "https://lrclib.net/api/get";
    private static final String SEARCH_ENDPOINT = "https://lrclib.net/api/search";
    private static final long MIN_INTERVAL_MS = 350;
    /** 读取超时；连接超时由 Http 统一控制（3.5s）。 */
    private static final int TIMEOUT_MS = 6000;
    /** 缓存条目上限（一首一个 key）。 */
    private static final int CACHE_LIMIT = 512;

    private final Map<String, List<Map<String, Object>>> cache =
            new ConcurrentHashMap<String, List<Map<String, Object>>>();

    /** 下一次可发请求的时间戳（票制限流）。 */
    private long nextSlot = 0;

    /** 最近一次查询的失败原因（空串表示没出错）。用 ThreadLocal 保证并发隔离。 */
    private final ThreadLocal<String> error = new ThreadLocal<String>();

    /** 最近一次查询的失败原因；空串表示没出错。用于把「查不到」和「连不上」区分开。 */
    public String lastError() {
        String e = error.get();
        return e == null ? "" : e;
    }

    private void setError(String message) {
        if (message == null || message.isEmpty()) {
            error.remove();
        } else {
            error.set(message);
        }
    }

    public static class Item {
        public String title = "";
        public String artist = "";
        public String album = "";
        public Double duration = null;
        public String synced = "";
        public String plain = "";
        public boolean instrumental = false;
        public boolean exact = false;

        public boolean hasLyrics() {
            return !synced.isEmpty() || !plain.isEmpty() || instrumental;
        }
    }

    public List<Item> lookup(String title, String artist, String album, Double duration) {
        List<Item> out = new ArrayList<Item>();
        setError("");
        title = title == null ? "" : title.trim();
        if (title.isEmpty()) {
            setError("没有可用的歌名");
            return out;
        }
        artist = artist == null ? "" : artist.trim();
        album = album == null ? "" : album.trim();
        String key = TextUtil.normCompare(title) + "|" + TextUtil.normCompare(artist)
                + "|" + (duration == null ? 0 : Math.round(duration));
        List<Map<String, Object>> cached = cache.get(key);
        if (cached != null) {
            return fromMaps(cached);
        }

        List<Item> candidates = new ArrayList<Item>();
        Map<String, String> params = new HashMap<String, String>();
        params.put("track_name", title);
        if (!artist.isEmpty()) {
            params.put("artist_name", artist);
        }
        if (!album.isEmpty()) {
            params.put("album_name", album);
        }
        if (duration != null && duration > 0) {
            params.put("duration", String.valueOf(Math.round(duration)));
        }
        throttle();
        Object payload = Http.getJson(Endpoints.url("lrclib", 0), params, null, TIMEOUT_MS);
        if (payload == null) {
            String err = Http.lastError();
            // 404 是「库里没有这首」，属于正常结果，不当作故障
            if (err != null && !err.startsWith("HTTP 404")) {
                setError(err);
            }
        }
        if (payload instanceof JSONObject) {
            Item item = normalize((JSONObject) payload);
            if (item.hasLyrics()) {
                item.exact = true;
                candidates.add(item);
            }
        }
        boolean hasSynced = false;
        for (Item item : candidates) {
            if (!item.synced.isEmpty()) {
                hasSynced = true;
                break;
            }
        }
        if (!hasSynced) {
            Map<String, String> searchParams = new HashMap<String, String>();
            searchParams.put("q", (title + " " + artist).trim());
            throttle();
            Object search = Http.getJson(Endpoints.url("lrclib", 1), searchParams, null, TIMEOUT_MS);
            if (search == null && lastError().isEmpty()) {
                String err = Http.lastError();
                if (err != null && !err.startsWith("HTTP 404")) {
                    setError(err);
                }
            }
            JSONArray list = null;
            if (search instanceof JSONArray) {
                list = (JSONArray) search;
            } else if (search instanceof JSONObject) {
                list = ((JSONObject) search).optJSONArray("data");
            }
            if (list != null) {
                for (int i = 0; i < list.length() && i < 10; i++) {
                    JSONObject node = list.optJSONObject(i);
                    if (node == null) {
                        continue;
                    }
                    Item item = normalize(node);
                    if (item.hasLyrics()) {
                        candidates.add(item);
                    }
                }
            }
        }

        // 排序：同步歌词优先 → 精确命中优先 → 时长接近优先
        final Double localDuration = duration;
        java.util.Collections.sort(candidates, new java.util.Comparator<Item>() {
            @Override
            public int compare(Item a, Item b) {
                int x = Boolean.compare(!a.synced.isEmpty(), !b.synced.isEmpty());
                if (x != 0) {
                    return -x;
                }
                x = Boolean.compare(a.exact, b.exact);
                if (x != 0) {
                    return -x;
                }
                double da = delta(a, localDuration);
                double db = delta(b, localDuration);
                return Double.compare(da, db);
            }

            private double delta(Item item, Double local) {
                if (item.duration == null || local == null) {
                    return Double.MAX_VALUE;
                }
                return Math.abs(item.duration - local);
            }
        });

        if (cache.size() > CACHE_LIMIT) {
            cache.clear();
        }
        cache.put(key, toMaps(candidates));
        return candidates;
    }

    private static Item normalize(JSONObject node) {
        Item item = new Item();
        item.title = node.optString("trackName", node.optString("name", "")).trim();
        item.artist = node.optString("artistName", "").trim();
        item.album = node.optString("albumName", "").trim();
        if (node.has("duration") && !node.isNull("duration")) {
            try {
                item.duration = node.getDouble("duration");
            } catch (Exception ignored) {
            }
        }
        item.synced = node.optString("syncedLyrics", "");
        item.plain = node.optString("plainLyrics", "");
        item.instrumental = node.optBoolean("instrumental", false);
        return item;
    }

    private static List<Map<String, Object>> toMaps(List<Item> items) {
        List<Map<String, Object>> out = new ArrayList<Map<String, Object>>();
        for (Item item : items) {
            Map<String, Object> m = new HashMap<String, Object>();
            m.put("title", item.title);
            m.put("artist", item.artist);
            m.put("album", item.album);
            m.put("duration", item.duration);
            m.put("synced", item.synced);
            m.put("plain", item.plain);
            m.put("instrumental", item.instrumental);
            m.put("exact", item.exact);
            out.add(m);
        }
        return out;
    }

    @SuppressWarnings("unchecked")
    private static List<Item> fromMaps(List<Map<String, Object>> maps) {
        List<Item> out = new ArrayList<Item>();
        for (Map<String, Object> m : maps) {
            Item item = new Item();
            item.title = String.valueOf(m.get("title"));
            item.artist = String.valueOf(m.get("artist"));
            item.album = String.valueOf(m.get("album"));
            Object dur = m.get("duration");
            item.duration = dur instanceof Double ? (Double) dur : null;
            item.synced = String.valueOf(m.get("synced"));
            item.plain = String.valueOf(m.get("plain"));
            item.instrumental = Boolean.TRUE.equals(m.get("instrumental"));
            item.exact = Boolean.TRUE.equals(m.get("exact"));
            out.add(item);
        }
        return out;
    }

    /**
     * 票制限流：锁内只预约发车时间，锁外 sleep。
     * 并发时多线程依次拿到 now、now+350ms、now+700ms… 而不是排队等整段请求结束。
     */
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
