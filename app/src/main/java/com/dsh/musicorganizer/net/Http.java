package com.dsh.musicorganizer.net;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.Iterator;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 极简 HTTP GET 工具（HttpURLConnection，零依赖）。
 * 返回 org.json.JSONObject / JSONArray（org.json 为 Android 框架自带）。
 *
 * <p>为了「批量取标签/歌词」的速度，这里做了三件事：
 * <ol>
 *   <li><b>连接复用</b>：成功读完 body 后<b>不</b>调用 disconnect()。
 *       老实现每次 finally 都 disconnect()，会把底层 socket 关掉，下一首还得重新
 *       DNS + TCP + TLS 握手（境外源一次握手 0.2~0.5s，几百首就是几分钟）。
 *       Android 的 HttpURLConnection 自带连接池，读完不关即可复用。</li>
 *   <li><b>失败熔断</b>：同一主机连续失败 2 次后冷却 45s，冷却期内请求立刻失败返回，
 *       不再让每一首都干等满超时。网络不通时 100 首从「几十分钟」降到「十几秒」。</li>
 *   <li><b>连接超时与读取超时分开</b>：连接 3.5s（握手该快就快），读取用调用方给的预算。</li>
 * </ol>
 */
public final class Http {

    public static final String USER_AGENT =
            "MusicOrganizerAndroid/2.5 (Android; local utility)";

    /** 连接（握手）超时：卡住就尽快判定这个源不可用。 */
    private static final int CONNECT_TIMEOUT_MS = 3500;
    /** 连续失败多少次后进入冷却。 */
    private static final int FAIL_THRESHOLD = 2;
    /** 冷却时长。 */
    private static final long COOLDOWN_MS = 45000L;
    /** 被限流（429）时冷却更久。 */
    private static final long RATE_LIMIT_COOLDOWN_MS = 90000L;

    private Http() {
    }

    /**
     * 最近一次请求的失败原因（null 表示成功）。
     * 用 ThreadLocal：所有网络请求都在后台工作线程，互不干扰。
     */
    private static final ThreadLocal<String> LAST_ERROR = new ThreadLocal<String>();

    public static String lastError() {
        return LAST_ERROR.get();
    }

    private static void clearError() {
        LAST_ERROR.remove();
    }

    private static void fail(String message) {
        LAST_ERROR.set(message);
    }

    // ------------------------------------------------------------------
    // 主机健康状态（熔断）
    // ------------------------------------------------------------------

    private static final class HostState {
        final AtomicInteger fails = new AtomicInteger();
        volatile long cooldownUntil = 0;
        volatile String reason = "";
    }

    private static final Map<String, HostState> HOSTS =
            new ConcurrentHashMap<String, HostState>();

    private static HostState state(String host) {
        HostState s = HOSTS.get(host);
        if (s == null) {
            HostState created = new HostState();
            HostState old = HOSTS.putIfAbsent(host, created);
            s = old == null ? created : old;
        }
        return s;
    }

    private static String hostOf(String url) {
        try {
            String h = new URL(url).getHost();
            return h == null ? url : h;
        } catch (Exception e) {
            return url;
        }
    }

    /** 该地址所属主机是否正在冷却（连续失败后短暂跳过）。 */
    public static boolean isCoolingDown(String url) {
        return state(hostOf(url)).cooldownUntil > System.currentTimeMillis();
    }

    /** 冷却剩余秒数；未冷却返回 0。 */
    public static long cooldownSecondsLeft(String url) {
        long left = state(hostOf(url)).cooldownUntil - System.currentTimeMillis();
        return left <= 0 ? 0 : (left / 1000 + 1);
    }

    private static void noteOk(HostState hs) {
        hs.fails.set(0);
        hs.cooldownUntil = 0;
        hs.reason = "";
    }

    private static void noteFail(HostState hs, String reason, long cooldownMs) {
        hs.reason = reason;
        if (hs.fails.incrementAndGet() >= FAIL_THRESHOLD) {
            hs.cooldownUntil = System.currentTimeMillis() + cooldownMs;
            hs.fails.set(0);
        }
    }

    // ------------------------------------------------------------------
    // GET
    // ------------------------------------------------------------------

    /** 带查询参数的 GET，返回 JSONObject / JSONArray / null。 */
    public static Object getJson(String url, Map<String, String> params,
                                 Map<String, String> headers, int timeoutMs) {
        String text = fetch(url, params, headers, timeoutMs);
        if (text == null) {
            return null;
        }
        try {
            return new org.json.JSONTokener(text).nextValue();
        } catch (Exception e) {
            fail("响应不是合法 JSON：" + url);
            return null;
        }
    }

    /**
     * GET 并返回原始字节（封面图片这类二进制用）。
     *
     * @param maxBytes 超过就中止并返回 null，防止一张巨图把内存吃光
     */
    public static byte[] getBytes(String url, Map<String, String> params,
                                  Map<String, String> headers, int timeoutMs, int maxBytes) {
        return fetchBytes(url, params, headers, timeoutMs, maxBytes);
    }

    /** GET 并返回原始文本（歌词接口的 JSON 也走这里）。 */
    public static String getText(String url, Map<String, String> params,
                                 Map<String, String> headers, int timeoutMs) {
        return fetch(url, params, headers, timeoutMs);
    }

    /**
     * 真正的请求实现。成功返回响应文本，任何失败返回 null 并把原因写进 lastError。
     * 成功路径不断开连接，让连接回到池里给下一个请求复用。
     */
    private static String fetch(String url, Map<String, String> params,
                                Map<String, String> headers, int timeoutMs) {
        byte[] body = fetchBytes(url, params, headers, timeoutMs, TEXT_MAX_BYTES);
        if (body == null) {
            return null;
        }
        try {
            String text = new String(body, "UTF-8").trim();
            if (text.isEmpty()) {
                fail("响应为空：" + hostOf(url));
                return null;
            }
            return text;
        } catch (Exception e) {
            return null;
        }
    }

    private static final int TEXT_MAX_BYTES = 4 * 1024 * 1024;

    private static byte[] fetchBytes(String url, Map<String, String> params,
                                     Map<String, String> headers, int timeoutMs, int maxBytes) {
        clearError();
        String host = hostOf(url);
        HostState hs = state(host);

        long now = System.currentTimeMillis();
        if (hs.cooldownUntil > now) {
            long sec = (hs.cooldownUntil - now) / 1000 + 1;
            fail("网络连续失败，已跳过 " + host + "（" + sec + " 秒后自动重试）"
                    + (hs.reason.isEmpty() ? "" : "：" + hs.reason));
            return null;
        }

        HttpURLConnection conn = null;
        boolean reusable = false;
        try {
            String full = buildUrl(url, params);
            conn = (HttpURLConnection) new URL(full).openConnection();
            conn.setConnectTimeout(Math.min(CONNECT_TIMEOUT_MS, timeoutMs));
            conn.setReadTimeout(timeoutMs);
            conn.setRequestMethod("GET");
            // keep-alive 是 HTTP/1.1 默认；显式声明避免个别 CDN 回 Connection: close
            conn.setRequestProperty("Connection", "keep-alive");
            conn.setRequestProperty("User-Agent", USER_AGENT);
            conn.setRequestProperty("Accept", "application/json, text/plain, */*");
            if (headers != null) {
                for (Map.Entry<String, String> e : headers.entrySet()) {
                    conn.setRequestProperty(e.getKey(), e.getValue());
                }
            }
            int code = conn.getResponseCode();
            if (code >= 400) {
                if (code == 404) {
                    // 库里没有这首，属于正常结果，不算网络故障
                    fail("HTTP 404");
                } else if (code == 429 || code == 403 || code == 405) {
                    // 429 是标准限流；403/405 在国内几家音乐站上常常也是「请求太频繁」，
                    // 一起按限流处理：短暂冷却，别让后面每首歌都去撞一次
                    noteFail(hs, "HTTP " + code + " 限流", RATE_LIMIT_COOLDOWN_MS);
                    fail("HTTP " + code + "（被限流，稍后自动重试）：" + host);
                } else if (code >= 500) {
                    noteFail(hs, "HTTP " + code, COOLDOWN_MS);
                    fail("HTTP " + code + "：" + host);
                } else {
                    fail("HTTP " + code + "：" + host);
                }
                return null;
            }
            InputStream in = conn.getInputStream();
            byte[] body;
            try {
                body = readAll(in, maxBytes);
            } finally {
                try {
                    in.close();
                } catch (Exception ignored) {
                }
            }
            noteOk(hs);
            // 读完且没有异常 → 连接可以回池复用，不要 disconnect
            reusable = true;
            if (body == null || body.length == 0) {
                fail("响应为空：" + host);
                return null;
            }
            return body;
        } catch (Exception e) {
            noteFail(hs, e.getClass().getSimpleName(), COOLDOWN_MS);
            fail(e.getClass().getSimpleName() + "：" + e.getMessage() + "（" + host + "）");
            return null;
        } finally {
            if (conn != null && !reusable) {
                try {
                    conn.disconnect();
                } catch (Exception ignored) {
                }
            }
        }
    }

    private static String buildUrl(String url, Map<String, String> params) throws Exception {
        if (params == null || params.isEmpty()) {
            return url;
        }
        StringBuilder sb = new StringBuilder(url);
        sb.append(url.indexOf('?') >= 0 ? '&' : '?');
        boolean first = true;
        for (Iterator<Map.Entry<String, String>> it = params.entrySet().iterator(); it.hasNext(); ) {
            Map.Entry<String, String> e = it.next();
            if (!first) {
                sb.append('&');
            }
            first = false;
            sb.append(URLEncoder.encode(e.getKey(), "UTF-8"));
            sb.append('=');
            sb.append(URLEncoder.encode(e.getValue(), "UTF-8"));
        }
        return sb.toString();
    }

    private static byte[] readAll(InputStream in, int maxBytes) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream(8192);
        byte[] buf = new byte[16384];
        int n;
        while ((n = in.read(buf)) > 0) {
            out.write(buf, 0, n);
            if (maxBytes > 0 && out.size() > maxBytes) {
                fail("响应超过 " + (maxBytes / 1024) + " KB，已中止");
                return null;
            }
        }
        return out.toByteArray();
    }
}
