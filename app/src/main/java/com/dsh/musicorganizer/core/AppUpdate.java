package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 应用更新判定 —— 解析 GitHub Release、比较版本号、把 Release 说明整理成可读文本。
 *
 * <p>为什么单独成一个类：版本比较和 JSON 解析都是「一次写对、以后不用再动」的纯逻辑，
 * 抽出来就能在桌面 JVM 里用固定样本跑回归（{@code tools/AppUpdateTest}），
 * 不用装 APK 去点按钮验证。
 *
 * <p>版本比较规则（实测 GitHub 上的 tag 五花八门，必须容错）：
 * <ol>
 *   <li>忽略前缀 {@code v} / {@code V}、前后空白，以及任何非数字分隔符；</li>
 *   <li>按数字段逐段比，缺的段补 0（{@code 0.1.10 > 0.1.9}，{@code 1.0 == 1.0.0}）；</li>
 *   <li>数字全相同时，带 {@code alpha/beta/rc/dev/preview} 后缀的算更旧
 *       （{@code 0.2.0-beta < 0.2.0}），避免把预发布当成正式版。</li>
 * </ol>
 *
 * <p>注意：这里<b>不</b>依赖 Android 与 org.json（用自家的 {@link Json}）。
 */
public final class AppUpdate {

    private AppUpdate() {
    }

    /** 兼容旧数据：release 里没有 assets 时，用这个拼下载地址的兜底前缀。 */
    public static final String APK_SUFFIX = ".apk";

    // ------------------------------------------------------------------
    // 数据结构
    // ------------------------------------------------------------------

    /** 一条 GitHub Release（只取本项目用得到的字段）。 */
    public static final class Release {
        /** 原始 tag，如 {@code v0.1.11} */
        public final String tag;
        /** 归一后的版本号，如 {@code 0.1.11} */
        public final String version;
        /** Release 标题（新建 release 时填的名字） */
        public final String title;
        /** Release 说明（Markdown 原文，可能很长） */
        public final String notes;
        /** 发布页地址（浏览器打开） */
        public final String pageUrl;
        /** APK 直链；没有 apk 资产时为空串 */
        public final String apkUrl;
        /** APK 文件名；没有时为空串 */
        public final String apkName;
        /** APK 字节数；未知为 0 */
        public final long apkSize;
        /** 是否预发布 */
        public final boolean prerelease;
        /** 发布时间（ISO 字符串，原样保留） */
        public final String publishedAt;

        Release(String tag, String title, String notes, String pageUrl,
                String apkUrl, String apkName, long apkSize, boolean prerelease,
                String publishedAt) {
            this.tag = tag;
            // 保留 -beta / -rc 这类后缀：compare 靠它判断预发布，
            // 只去掉 v 前缀（normalize 会把这些后缀一起丢掉，不能用来判版本）
            this.version = stripPrefix(tag);
            this.title = title;
            this.notes = notes;
            this.pageUrl = pageUrl;
            this.apkUrl = apkUrl;
            this.apkName = apkName;
            this.apkSize = apkSize;
            this.prerelease = prerelease;
            this.publishedAt = publishedAt;
        }

        /** 有没有可直接下载的 APK 资产（没有就退到发布页）。 */
        public boolean hasApk() {
            return apkUrl != null && !apkUrl.isEmpty();
        }

        @Override
        public String toString() {
            return tag + (apkName.isEmpty() ? "" : " · " + apkName);
        }
    }

    // ------------------------------------------------------------------
    // 解析 GitHub Release JSON
    // ------------------------------------------------------------------

    /**
     * 解析 {@code /repos/{owner}/{repo}/releases/latest} 的响应。
     *
     * <p>返回 null 的情况：不是 JSON、不是对象、缺 {@code tag_name}
     * （通常是代理返回了 HTML 错误页，或者仓库一个 release 都没有 —— 后者 GitHub 会给 404）。
     */
    public static Release parseRelease(String json) {
        Object root = Json.parseOrNull(json);
        if (!(root instanceof Map)) {
            return null;
        }
        Map<?, ?> m = (Map<?, ?>) root;
        String tag = str(m, "tag_name").trim();
        if (tag.isEmpty()) {
            return null;
        }
        String title = str(m, "name").trim();
        if (title.isEmpty()) {
            title = tag;
        }
        String notes = str(m, "body");
        String page = str(m, "html_url");
        String published = str(m, "published_at");
        boolean pre = bool(m, "prerelease") || bool(m, "draft");

        // assets：优先取第一个 .apk（GitHub 上的文件名带中文，API 给的
        // browser_download_url 已经做过百分号编码，直接丢给浏览器就能下）
        String apkUrl = "";
        String apkName = "";
        long apkSize = 0;
        Object assets = m.get("assets");
        if (assets instanceof List) {
            for (Object o : (List<?>) assets) {
                if (!(o instanceof Map)) {
                    continue;
                }
                Map<?, ?> a = (Map<?, ?>) o;
                String name = str(a, "name");
                if (!name.toLowerCase().endsWith(APK_SUFFIX)) {
                    continue;
                }
                String dl = str(a, "browser_download_url");
                if (dl.isEmpty()) {
                    continue;
                }
                apkUrl = dl;
                apkName = name;
                apkSize = (long) num(a, "size");
                break;
            }
        }
        return new Release(tag, title, notes, page, apkUrl, apkName, apkSize, pre, published);
    }

    private static String str(Map<?, ?> m, String key) {
        Object v = m.get(key);
        return v == null ? "" : String.valueOf(v);
    }

    // ------------------------------------------------------------------
    // 解析「版本清单」纯文本（国内镜像首选这条路，v0.1.78）
    // ------------------------------------------------------------------

    /**
     * 解析仓库里的 {@code dist/latest.txt}。
     *
     * <p><b>为什么要多一条纯文本通道</b>：GitHub 的 Release API 在境内经常连不上，
     * 而且匿名调用有频率限制。Gitee 的 raw 文件是普通静态资源 —— 不需要 token、
     * 不限速、国内快，正好用来放「最新版本是谁、装包在哪」这一小段信息。
     *
     * <p>格式是每行 {@code key=value}，{@code #} 开头是注释：
     * <pre>
     * version=0.1.78-ab12cd
     * code=88
     * tag=v0.1.78-ab12cd
     * apk=dist/musicorganizer-latest.apk
     * size=357839
     * page=https://gitee.com/kakadex/MusicOrganizer/releases
     * summary=一句话说明
     * date=2026-10-25
     * </pre>
     *
     * @param text        清单内容
     * @param manifestUrl 清单自身的地址（用来把相对路径的 apk 拼成绝对直链）
     * @return 解析结果；缺少 version/tag 或格式不像清单时返回 null
     */
    public static Release parseManifest(String text, String manifestUrl) {
        if (text == null || text.trim().isEmpty()) {
            return null;
        }
        Map<String, String> kv = new HashMap<String, String>();
        for (String raw : text.split("\\r?\\n")) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("#")) {
                continue;
            }
            int eq = line.indexOf('=');
            if (eq <= 0) {
                continue;
            }
            kv.put(line.substring(0, eq).trim().toLowerCase(java.util.Locale.ROOT),
                    line.substring(eq + 1).trim());
        }
        String version = kv.containsKey("version") ? kv.get("version") : "";
        String tag = kv.containsKey("tag") ? kv.get("tag") : "";
        if (version.isEmpty() && tag.isEmpty()) {
            return null;
        }
        if (tag.isEmpty()) {
            tag = "v" + version;
        }
        String summary = kv.containsKey("summary") ? kv.get("summary") : "";
        String page = kv.containsKey("page") ? kv.get("page") : "";
        String rel = kv.containsKey("apk") ? kv.get("apk") : "";
        String apkUrl = resolve(manifestUrl, rel);
        String apkName = rel.isEmpty() ? "" : rel.substring(rel.lastIndexOf('/') + 1);
        long size = 0L;
        try {
            String s = kv.containsKey("size") ? kv.get("size") : "";
            if (!s.isEmpty()) {
                size = Long.parseLong(s);
            }
        } catch (NumberFormatException ignored) {
            // 体积只是用来显示的，解析不出来就当未知
        }
        boolean pre = tag.toLowerCase(java.util.Locale.ROOT).contains("beta")
                || tag.toLowerCase(java.util.Locale.ROOT).contains("rc")
                || tag.toLowerCase(java.util.Locale.ROOT).contains("alpha");
        String published = kv.containsKey("date") ? kv.get("date") : "";
        return new Release(tag, summary.isEmpty() ? tag : summary, summary, page,
                apkUrl, apkName, size, pre, published);
    }

    /**
     * 把清单里的相对路径拼成绝对地址。
     *
     * <p>清单在 {@code .../raw/main/dist/latest.txt}，那么 {@code dist/x.apk}
     * 就是 {@code .../raw/main/dist/x.apk}：砍掉清单地址的最后两段再把相对路径接上，
     * 这样 Gitee 和 GitHub 两个域名的 raw 前缀都能自动适配。
     */
    public static String resolve(String manifestUrl, String rel) {
        if (rel == null || rel.isEmpty()) {
            return "";
        }
        String r = rel.trim();
        if (r.startsWith("http://") || r.startsWith("https://")) {
            return r;
        }
        if (manifestUrl == null || manifestUrl.isEmpty()) {
            return "";
        }
        String base = manifestUrl;
        // 去掉查询串/锚点，免得在后面留下垃圾
        int q = base.indexOf('?');
        if (q > 0) {
            base = base.substring(0, q);
        }
        int cut = base.lastIndexOf('/');
        if (cut > 0) {
            base = base.substring(0, cut);          // 去掉 latest.txt
        }
        cut = base.lastIndexOf('/');
        if (cut > 0) {
            base = base.substring(0, cut + 1);      // 去掉 dist，保留末尾斜杠
        }
        return base + r;
    }

    private static boolean bool(Map<?, ?> m, String key) {
        Object v = m.get(key);
        return v instanceof Boolean && ((Boolean) v).booleanValue();
    }

    private static double num(Map<?, ?> m, String key) {
        Object v = m.get(key);
        return v instanceof Number ? ((Number) v).doubleValue() : 0d;
    }

    // ------------------------------------------------------------------
    // 版本比较
    // ------------------------------------------------------------------

    /** 去掉前缀 v、空白，但**保留**后缀（{@code " v0.2.0-beta " → "0.2.0-beta"}）。 */
    public static String stripPrefix(String version) {
        if (version == null) {
            return "";
        }
        String s = version.trim();
        while (s.startsWith("v") || s.startsWith("V")) {
            s = s.substring(1).trim();
        }
        return s;
    }

    /** 去掉前缀 v、空白和多余分隔符，只留数字段（{@code "v0.1.11 " → "0.1.11"}）。 */
    public static String normalize(String version) {
        int[] p = parts(version);
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < p.length; i++) {
            if (i > 0) {
                sb.append('.');
            }
            sb.append(p[i]);
        }
        return sb.toString();
    }

    /**
     * 取版本主体的数字段（最多 4 段，再多基本是日期型 tag）。
     *
     * <p>关键点：<b>一旦读到数字之后再遇到字母就停下</b>。GitHub 的 tag 可能是
     * {@code 0.2.0-rc1}，如果把 {@code rc1} 里的 1 也当第 4 段，
     * {@code 0.2.0-rc1} 就会比 {@code 0.2.0} 还新 —— 装上去反而是降级。
     * 开头的字母块（{@code release-2026-10-22}）仍允许跳过，日期型 tag 也认得。
     */
    private static int[] parts(String version) {
        if (version == null) {
            return new int[0];
        }
        String s = stripPrefix(version);
        List<Integer> out = new ArrayList<Integer>();
        int i = 0;
        int n = s.length();
        while (i < n && out.size() < 4) {
            char c = s.charAt(i);
            if (c < '0' || c > '9') {
                // a-z/A-Z 出现在数字之后 = 预发布后缀开始了，主体到此为止
                if (!out.isEmpty() && isAsciiLetter(c)) {
                    break;
                }
                i++;
                continue;
            }
            long v = 0;
            while (i < n && s.charAt(i) >= '0' && s.charAt(i) <= '9') {
                v = v * 10 + (s.charAt(i) - '0');
                if (v > Integer.MAX_VALUE) {
                    v = Integer.MAX_VALUE;
                }
                i++;
            }
            out.add(Integer.valueOf((int) v));
        }
        int[] arr = new int[out.size()];
        for (int k = 0; k < arr.length; k++) {
            arr[k] = out.get(k).intValue();
        }
        return arr;
    }

    private static boolean isAsciiLetter(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    /** 预发布后缀：0 = 是预发布，1 = 正式版。正式版永远大于同号的预发布。 */
    private static int preRank(String version) {
        if (version == null) {
            return 1;
        }
        String s = version.toLowerCase();
        String[] marks = {"alpha", "beta", "rc", "dev", "preview", "snapshot", "test"};
        for (String m : marks) {
            if (s.contains(m)) {
                return 0;
            }
        }
        return 1;
    }

    /**
     * 比较两个版本号：a 更旧返回负数，相同返回 0，a 更新返回正数。
     * 任何非法输入都不会抛异常（缺段按 0 处理）—— 比「解析失败就当最新」安全得多。
     */
    public static int compare(String a, String b) {
        int[] x = parts(a);
        int[] y = parts(b);
        int n = Math.max(x.length, y.length);
        for (int i = 0; i < n; i++) {
            int p = i < x.length ? x[i] : 0;
            int q = i < y.length ? y[i] : 0;
            if (p != q) {
                return p < q ? -1 : 1;
            }
        }
        int ra = preRank(a);
        int rb = preRank(b);
        if (ra == rb) {
            return 0;
        }
        return ra < rb ? -1 : 1;
    }

    /** remote 是否比 installed 新（两者都可以带 v 前缀）。 */
    public static boolean isNewer(String installed, String remote) {
        if (remote == null || remote.trim().isEmpty()) {
            return false;
        }
        return compare(remote, installed) > 0;
    }

    /** 给界面用的展示串（带 v；不含数字的输入原样返回）。 */
    public static String display(String version) {
        String s = stripPrefix(version);
        if (s.isEmpty()) {
            return "";
        }
        char c = s.charAt(0);
        return (c >= '0' && c <= '9') ? "v" + s : s;
    }

    // ------------------------------------------------------------------
    // Release 说明美化
    // ------------------------------------------------------------------

    /**
     * 把 Markdown 说明压成一段纯文本（最多 {@code maxLines} 行、约 600 字）。
     *
     * <p>Release 说明常常有一两百行（本项目的说明尤其长），弹窗里必须截断，
     * 完整内容留给「打开发布页」。
     */
    public static String shortNotes(String body, int maxLines) {
        if (body == null || body.trim().isEmpty()) {
            return "";
        }
        String[] raw = body.replace("\r\n", "\n").replace('\r', '\n').split("\n");
        List<String> lines = new ArrayList<String>();
        boolean lastBlank = true;
        int chars = 0;
        for (String line : raw) {
            String s = plain(line);
            if (s.isEmpty()) {
                if (!lastBlank && !lines.isEmpty()) {
                    lines.add("");
                    lastBlank = true;
                }
                continue;
            }
            if (lines.size() >= maxLines) {
                lines.add("…");
                return join(lines);
            }
            chars += s.length();
            if (chars > 900) {
                lines.add(s.length() > 60 ? s.substring(0, 60) + "…" : s);
                lines.add("…（完整说明见发布页）");
                return join(lines);
            }
            lines.add(s);
            lastBlank = false;
        }
        return join(lines);
    }

    /** 去掉 Markdown 标记，只留人能读的文字（列表符号保留，读起来更有层次）。 */
    static String plain(String line) {
        if (line == null) {
            return "";
        }
        String s = line.trim();
        if (s.startsWith("```")) {
            return "";
        }
        // 标题：### 新增 → 【新增】
        int hash = 0;
        while (hash < s.length() && s.charAt(hash) == '#') {
            hash++;
        }
        if (hash > 0 && hash < s.length() && s.charAt(hash) == ' ') {
            return "【" + s.substring(hash + 1).trim() + "】";
        }
        // 引用块 > xxx
        while (s.startsWith(">")) {
            s = s.substring(1).trim();
        }
        // 粗体 / 行内代码 / 删除线
        s = s.replace("**", "").replace("__", "").replace("`", "").replace("~~", "");
        // 链接 [文字](地址) → 文字
        s = stripLinks(s);
        // 分隔线
        if (s.matches("[-*_]{3,}")) {
            return "";
        }
        return s.trim();
    }

    private static String stripLinks(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        int i = 0;
        while (i < s.length()) {
            char c = s.charAt(i);
            int close = c == '[' ? s.indexOf(']', i) : -1;
            if (close > i && close + 1 < s.length() && s.charAt(close + 1) == '(') {
                int end = s.indexOf(')', close + 2);
                if (end > 0) {
                    sb.append(s, i + 1, close);
                    i = end + 1;
                    continue;
                }
            }
            sb.append(c);
            i++;
        }
        return sb.toString();
    }

    private static String join(List<String> lines) {
        StringBuilder sb = new StringBuilder();
        for (String l : lines) {
            if (sb.length() > 0 || !l.isEmpty()) {
                if (sb.length() > 0) {
                    sb.append('\n');
                }
                sb.append(l);
            }
        }
        return sb.toString().trim();
    }

    /** 字节数转「12.3 MB」（APK 大小给用户看的）。 */
    public static String humanSize(long bytes) {
        if (bytes <= 0) {
            return "";
        }
        if (bytes < 1024) {
            return bytes + " B";
        }
        double kb = bytes / 1024d;
        if (kb < 1024) {
            return String.format(java.util.Locale.US, "%.0f KB", Double.valueOf(kb));
        }
        double mb = kb / 1024d;
        return String.format(java.util.Locale.US, "%.1f MB", Double.valueOf(mb));
    }
}
