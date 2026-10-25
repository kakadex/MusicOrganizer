package com.dsh.musicorganizer.core;

import android.content.ContentResolver;

import com.dsh.musicorganizer.net.Endpoints;
import com.dsh.musicorganizer.net.LrcClient;
import com.dsh.musicorganizer.net.LyricSources;
import com.dsh.musicorganizer.net.Net;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 歌词获取与写入 —— 对应 Python 版批量歌词功能（多源兜底 + 同名 .lrc）。
 *
 * <p><b>多源兜底</b>：网易云 / QQ 音乐 / 酷狗 / LRCLIB / lyrics.ovh 五家同时查，
 * 打分时**国内源优先**（中文歌国内站是官方录入，酷狗与网易还带逐字轴），
 * LRCLIB 留作外语歌与规范时间轴的补充。
 * 以前只有 LRCLIB 一家，而它是境外站，国内网络下经常连不上，中文歌的匹配率被这条通道卡死。
 *
 * <p><b>防配错</b>：歌词配错比没配上更糟，所以候选要过三道关 ——
 * 标题相似度、艺人相似度、时长差（&gt;6s 直接弃），外加变体词过滤
 * （伴奏 / 现场 / remix 之类，除非本地歌名本身也带）。逐首文件的最终取舍只在这里做一次，
 * 各源不各自判定，避免标准打架。
 *
 * <p>质量校验：时间轴行数 / 单调性 / 行数 / 字符数；纯文本歌词默认只提示不写。
 */
public final class Lyrics {

    private Lyrics() {
    }

    /** 单首的源级总预算：四家同时查，最慢那家收口。 */
    private static final long LYRIC_SOURCE_BUDGET_MS = 9000L;

    private static final Pattern LRC_TS_RE =
            Pattern.compile("\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]");

    /**
     * 变体词：候选标题里带这些词、而本地标题里没有，就判定为「不是同一首」。
     * 典型场景：本地是《晴天》，库里搜到《晴天 (伴奏)》排第一 —— 配上去整首歌就对不上了。
     */
    private static final Pattern VARIANT_RE = Pattern.compile(
            "伴奏|纯音乐|instrumental|karaoke|ktv|remix|现场|live|cover|翻唱|片段|铃声|试听|串烧|抖音|女声版|男声版");

    /** 返回质量错误信息；"" 表示通过。 */
    public static String qualityError(String text) {
        if (text == null || text.trim().isEmpty()) {
            return "歌词为空";
        }
        List<double[]> stamps = new ArrayList<double[]>();
        String[] lines = text.split("\n");
        for (String line : lines) {
            Matcher m = LRC_TS_RE.matcher(line);
            if (m.find()) {
                double minutes = Integer.parseInt(m.group(1));
                double seconds = Integer.parseInt(m.group(2));
                String frac = m.group(3) == null ? "0" : m.group(3);
                double millis = Integer.parseInt((frac + "00").substring(0, 3));
                stamps.add(new double[]{minutes * 60 + seconds + millis / 1000.0});
            }
        }
        if (stamps.isEmpty()) {
            return "纯文本歌词（无时间轴）";
        }
        if (stamps.size() < 4) {
            return "时间轴行数过少（" + stamps.size() + "）";
        }
        for (int i = 1; i < stamps.size(); i++) {
            if (stamps.get(i)[0] < stamps.get(i - 1)[0]) {
                return "时间轴非单调递增";
            }
        }
        if (text.length() > 200000) {
            return "歌词过长";
        }
        return "";
    }

    /**
     * 一个词源候选的统一形态。LRCLIB 的 Item 与国内源的 Hit 字段不同，
     * 在这里抹平后再统一打分，避免「每个源一套标准」。
     */
    private static final class Offer {
        String source = "";
        String title = "";
        String artist = "";
        Double duration = null;
        String synced = "";
        String plain = "";
        /** 译文轨（网易 tlyric / QQ trans） */
        String translation = "";
        double score = 0;

        String text() {
            return !synced.isEmpty() ? synced : plain;
        }
    }

    /** 一次查询的结果：要么拿到可用歌词，要么记下「找到了但为什么不能用」。 */
    /**
     * 是否把歌词转成简体（设置项 {@code lyrics_simplify}，默认开）。
     *
     * <p>用静态开关而不是加参数：{@link #lookup} 是私有的，批量与单曲两条链路最后都汇到它，
     * 在这里一处拦截最不容易漏；调用方（{@code MainActivity} / 设置开关）只需同步一次。
     */
    private static volatile boolean simplify = true;

    /** 设置同步入口：关掉后不再做繁→简转换（已写入的歌词不受影响）。 */
    public static void setSimplify(boolean on) {
        simplify = on;
    }

    public static boolean simplifyEnabled() {
        return simplify;
    }

    private static final class Lookup {
        String content = "";
        /** 非空表示：接口有返回，但内容没通过质量校验 */
        String reject = "";
        boolean found = false;
        /** 命中的源（显示名），如「网易云」 */
        String sourceLabel = "";
        /** 合并进正文的译文行数（0 表示这首没有译文） */
        int translationLines = 0;
        /** 正文是否做过繁→简转换（预览里标一下，方便用户判断要不要关） */
        boolean simplified = false;
        /** 本次查询里各源的网络失败原因（空表示都通） */
        String networkError = "";
    }

    private static Offer toOffer(LyricSources.Hit hit) {
        Offer o = new Offer();
        o.source = hit.source;
        o.title = hit.title;
        o.artist = hit.artist;
        o.duration = hit.duration;
        o.synced = hit.synced;
        o.plain = hit.plain;
        o.translation = hit.translation;
        return o;
    }

    /**
     * 查一次歌词：<b>四个源并发</b>，回来后统一打分择优。
     *
     * <p>老实现是「串行问 LRCLIB 的 /api/get，没有再 /api/search」，两次往返，
     * 且只有一家；国内网络连不上时整批歌词全部失败。现在四家同时发车，
     * 耗时从「各源之和」降到「最慢那家」，且换了任何一家挂了都不至于全员阵亡。
     *
     * @param cancel 可为 null；用户停止时不必等剩下的源
     */
    private static Lookup lookup(final LrcClient client, final String title, final String artist,
                                 final String album, final Double duration,
                                 final boolean acceptPlain, final CancelToken cancel) {
        final Lookup out = new Lookup();
        final Map<String, String> errors = new ConcurrentHashMap<String, String>();

        // 各源是否启用（「数据源设置」里可单独关掉；关了就不发请求、不占超时）
        final boolean useLrclib = Endpoints.enabled("lrclib");
        final boolean useNetease = Endpoints.enabled("lyric_netease");
        final boolean useQq = Endpoints.enabled("lyric_qq");
        final boolean useOvh = Endpoints.enabled("lyric_ovh");
        final boolean useKugou = Endpoints.enabled("lyric_kugou");

        List<Callable<List<Offer>>> tasks = new ArrayList<Callable<List<Offer>>>(5);

        // ① LRCLIB：同步轴最规范，优先信任
        tasks.add(new Callable<List<Offer>>() {
            @Override
            public List<Offer> call() {
                List<Offer> list = new ArrayList<Offer>();
                if (!useLrclib) {
                    return new ArrayList<Offer>();
                }
                try {
                    for (LrcClient.Item item : client.lookup(title, artist, album, duration)) {
                        Offer o = new Offer();
                        o.source = "lrclib";
                        o.title = item.title;
                        o.artist = item.artist;
                        o.duration = item.duration;
                        o.synced = item.synced;
                        o.plain = item.plain;
                        list.add(o);
                    }
                } catch (Exception ignored) {
                    // 单源异常只少一家的结果
                }
                String err = client.lastError();
                if (err != null && !err.isEmpty()) {
                    errors.put("lrclib", err);
                }
                return list;
            }
        });

        // ② 网易云：中文曲库最全，且歌词带时间轴
        tasks.add(new Callable<List<Offer>>() {
            @Override
            public List<Offer> call() {
                List<Offer> list = new ArrayList<Offer>();
                if (!useNetease) {
                    return new ArrayList<Offer>();
                }
                try {
                    for (LyricSources.Hit hit : LyricSources.netease(title, artist, duration)) {
                        list.add(toOffer(hit));
                    }
                } catch (Exception ignored) {
                }
                noteHttpError(errors, LyricSources.NETEASE);
                return list;
            }
        });

        // ③ QQ 音乐：补充源
        tasks.add(new Callable<List<Offer>>() {
            @Override
            public List<Offer> call() {
                List<Offer> list = new ArrayList<Offer>();
                if (!useQq) {
                    return new ArrayList<Offer>();
                }
                try {
                    for (LyricSources.Hit hit : LyricSources.qq(title, artist, duration)) {
                        list.add(toOffer(hit));
                    }
                } catch (Exception ignored) {
                }
                noteHttpError(errors, LyricSources.QQMUSIC);
                return list;
            }
        });

        // ⑤ 酷狗：KRC 逐字优先，解不出自动降级为明文 LRC（v0.1.41）
        tasks.add(new Callable<List<Offer>>() {
            @Override
            public List<Offer> call() {
                List<Offer> list = new ArrayList<Offer>();
                if (!useKugou) {
                    return new ArrayList<Offer>();
                }
                try {
                    for (LyricSources.Hit hit : LyricSources.kugou(title, artist, duration)) {
                        list.add(toOffer(hit));
                    }
                } catch (Exception ignored) {
                }
                noteHttpError(errors, LyricSources.KUGOU);
                return list;
            }
        });

        // ④ lyrics.ovh：只有纯文本，作为「连不上国内站也拿不到 LRC」时的最后兜底
        tasks.add(new Callable<List<Offer>>() {
            @Override
            public List<Offer> call() {
                List<Offer> list = new ArrayList<Offer>();
                if (!useOvh) {
                    return new ArrayList<Offer>();
                }
                try {
                    for (LyricSources.Hit hit : LyricSources.ovh(title, artist)) {
                        list.add(toOffer(hit));
                    }
                } catch (Exception ignored) {
                }
                noteHttpError(errors, LyricSources.OVH);
                return list;
            }
        });

        List<Offer> all = new ArrayList<Offer>();
        for (List<Offer> part : Net.gather(tasks, LYRIC_SOURCE_BUDGET_MS, cancel)) {
            if (part != null) {
                all.addAll(part);
            }
        }
        out.found = !all.isEmpty();

        // 打分：不达标的直接排除（返回 -1），剩下的按分高到低
        final boolean chinese = hasHan(title) || hasHan(artist);
        List<Offer> ranked = new ArrayList<Offer>();
        for (Offer o : all) {
            o.score = offerScore(o, title, artist, duration, chinese);
            if (o.score > 0) {
                ranked.add(o);
            }
        }
        Collections.sort(ranked, new Comparator<Offer>() {
            @Override
            public int compare(Offer a, Offer b) {
                return Double.compare(b.score, a.score);
            }
        });

        String qualityReject = "";
        // 中文曲目优先国内源、外文曲目优先 LRCLIB（时间轴最规范）
        for (Offer o : ranked) {
            // TTML（QQ / 酷狗 / YT 抓取常见）先转 LRC：否则会被「没有时间轴」直接判不合格，
            // 或者整段 XML 写进文件，播放器只显示一串标签。
            String candidate = LyricsDoc.normalizeFormat(o.text());
            if (candidate == null || candidate.trim().isEmpty()) {
                continue;
            }
            String err = qualityError(candidate);
            if (err.isEmpty() || (acceptPlain && err.equals(PLAIN_ONLY))) {
                // 质量判断永远对「原文」做；翻译只影响最终写出的正文
                out.content = LyricsDoc.mergeTranslation(candidate, o.translation);
                if (out.content.trim().isEmpty()) {
                    out.content = LyricsDoc.clean(candidate);
                }
                out.translationLines = LyricsDoc.translationLineCount(out.content);
                // 繁 → 简：港台源（尤其 QQ / 网易的繁体条目）给的是繁体，
                // 放在「合并译文之后」统一转一次，原文与译文一起变简体；
                // 日文歌词（含假名）会被 Zh 自动跳过，不会误伤。
                if (simplify) {
                    String simplified = Zh.toSimplified(out.content);
                    if (!simplified.equals(out.content)) {
                        out.content = simplified;
                        out.simplified = true;
                    }
                }
                out.sourceLabel = sourceLabelOf(o.source);
                return out;
            }
            if (qualityReject.isEmpty()) {
                qualityReject = err;
            }
        }

        // 全被撂下：说清是「对不上人」还是「歌词本身不合格」
        if (!qualityReject.isEmpty()) {
            out.reject = qualityReject;
        } else if (!all.isEmpty()) {
            out.reject = "候选与本地歌曲差异过大（标题 / 艺人 / 时长对不上）";
        }
        if (!errors.isEmpty()) {
            StringBuilder sb = new StringBuilder();
            for (Map.Entry<String, String> e : errors.entrySet()) {
                if (sb.length() > 0) {
                    sb.append("；");
                }
                sb.append(sourceLabelOf(e.getKey())).append(" ").append(e.getValue());
            }
            out.networkError = sb.toString();
        }
        return out;
    }

    private static final String PLAIN_ONLY = "纯文本歌词（无时间轴）";

    /** 记录某个源的 HTTP 失败原因（Http.lastError 是 ThreadLocal，必须在当前任务线程里取）。 */
    private static void noteHttpError(Map<String, String> errors, String source) {
        String err = com.dsh.musicorganizer.net.Http.lastError();
        if (err != null && !err.isEmpty()) {
            errors.put(source, err);
        }
    }

    private static String sourceLabelOf(String source) {
        if ("lrclib".equals(source)) {
            return "LRCLIB";
        }
        return LyricSources.label(source);
    }

    /** 文本是否「像中文曲目」：含汉字且不像日文（日文假名优先判定）。 */
    private static boolean hasHan(String s) {
        if (s == null || s.isEmpty()) {
            return false;
        }
        return TextUtil.containsChinese(s) && !Zh.isJapanese(s);
    }

    /** 同分时优先用「同步轴更规范」的源，依次为 LRCLIB → 网易云 → QQ → ovh。 */
    /**
     * 源权重（语言感知）。
     *
     * <p><b>中文曲目</b>：国内站是官方录入（网易/酷狗还带逐字轴），错字与错行比社区库少，
     * 所以国内源权重最高；LRCLIB 时间轴规范、外语歌覆盖广，留 0.04 而非清零。
     *
     * <p><b>外文曲目</b>：国内站多为罗马字译名，不宜优先；此时只让 LRCLIB（时间轴最规范、外语覆盖广）
     * 略加权，其余国内源不再加分，避免把外文歌错配到国内站的译名条目。
     *
     * <p>这几个 0.04~0.06 的差距只在「标题 / 艺人 / 时长都接近」时才起作用（见
     * {@link #offerScore}）；明显不是同一首歌的候选在前面就被排除了，不靠这点权重兜。
     */
    private static double sourceBonus(String source, boolean chinese) {
        if ("lrclib".equals(source)) {
            return chinese ? 0.04 : 0.06;
        }
        if (!chinese) {
            return 0; // 非中文曲目不偏向国内源
        }
        if (LyricSources.NETEASE.equals(source) || LyricSources.KUGOU.equals(source)) {
            return 0.06;
        }
        if (LyricSources.QQMUSIC.equals(source)) {
            return 0.05;
        }
        return 0;
    }

    /**
     * 候选打分；返回 &lt;=0 表示「这不是同一首歌」，直接排除。
     *
     * <p>三道关：标题相似度 ≥0.60、艺人相似度 ≥0.50（任一方缺艺人信息则放宽）、
     * 时长差 ≤6s。外加变体词过滤 —— 这几条不是保守，是必需：
     * 歌词错位比没有歌词更让人恼火，而且用户很难发现。
     *
     * @param chinese 曲目是否中文，用于决定源权重偏向（见 {@link #sourceBonus}）
     */
    private static double offerScore(Offer o, String title, String artist, Double duration,
                                     boolean chinese) {
        if (isVariant(o.title, title)) {
            return -1;
        }
        double ts = TextUtil.textSimilarity(TextUtil.safeStr(title), o.title);
        if (ts < 0.60) {
            return -1;
        }
        double as;
        if (TextUtil.safeStr(artist).isEmpty() || TextUtil.safeStr(o.artist).isEmpty()) {
            as = 0.55; // 缺一方信息，不给满分也不当作证据
        } else {
            as = TextUtil.bestArtistSimilarity(artist, o.artist);
            if (as < 0.50) {
                return -1;
            }
        }
        double ds;
        if (duration == null || duration <= 0) {
            ds = 0.5;
        } else if (o.duration == null || o.duration <= 0) {
            ds = 0.4;
        } else {
            double diff = Math.abs(duration - o.duration);
            if (diff > 6) {
                return -1; // 差 6 秒以上，基本可以确定不是同一录音
            }
            ds = diff <= 2 ? 1.0 : 1.0 - (diff - 2) / 8.0;
        }
        double score = 0.45 * ts + 0.25 * as + 0.25 * ds + sourceBonus(o.source, chinese);
        if (!o.synced.isEmpty()) {
            score += 0.05;
        }
        return score;
    }

    /** 候选标题含变体词而本地标题不含 → 判为不同版本（伴奏 / 现场 / remix …）。 */
    private static boolean isVariant(String candidate, String local) {
        String c = TextUtil.normCompare(candidate);
        if (c.isEmpty()) {
            return true;
        }
        String l = TextUtil.normCompare(local);
        Matcher m = VARIANT_RE.matcher(c);
        while (m.find()) {
            if (!l.contains(m.group())) {
                return true;
            }
        }
        return false;
    }

    /**
     * 一条「待确认」的歌词匹配结果。fetchMatches 只收集，不写文件；
     * 用户预览确认后再交给 writeMatches 落盘。
     */
    public static class Match {
        public VFile file;
        public String title = "";
        public String artist = "";
        public String content = "";
        public boolean timeline = false;
        /** 预览里的补充说明，如「纯文本歌词（无时间轴）」 */
        public String note = "";
        /** 歌词来自哪个源（LRCLIB / 网易云 / QQ 音乐 / lyrics.ovh），预览里显示 */
        public String sourceLabel = "";
        /** 正文里包含的译文行数（0 = 只有原文） */
        public int translationLines = 0;
        /** 正文是否由繁体转成了简体（预览里标「已转简体」） */
        public boolean simplified = false;
        /** 是否默认勾选（纯文本等低质量结果默认不勾） */
        public boolean selected = true;
        /** 这条是从中间态队列续跑来的（没重新联网）。 */
        public boolean resumed;
    }

    /**
     * 批量匹配的统计结果。**为什么要这个**：以前只返回空列表，
     * 界面只能弹「没有匹配到歌词」，用户无法分辨是「没扫到文件 / 已有 lrc 跳过 /
     * 认不出歌名 / 库里没有 / 连不上网」。现在每种情况都有计数，界面按实际情况提示。
     */
    public static class FetchResult {
        public final List<Match> matches = new ArrayList<Match>();
        /** 传进来待处理的文件数 */
        public int scanned = 0;
        /** 其中可处理的音频文件数 */
        public int audio = 0;
        /** 已有同名 .lrc 且未开覆盖 */
        public int skippedExisting = 0;
        /** 文件名/标签都认不出歌名 */
        public int noTitle = 0;
        /** 接口有返回，但歌词没通过质量校验 */
        public int rejected = 0;
        /** 校验拒绝的原因示例，如「纯文本歌词（无时间轴）」 */
        public String rejectNote = "";
        /** 库里确实没有 */
        public int notFound = 0;
        /** 按匹配记忆跳过（上批已确认查不到 / 已写入） */
        public int skippedKnown = 0;
        /** 处理异常 */
        public int failed = 0;
        /** 用户中途停止 */
        public boolean stopped = false;
        /** 网络层错误（连不上 / 超时 / 证书等） */
        public String networkError = "";
        /** 异常示例 */
        public String errorNote = "";

        public boolean isEmpty() {
            return matches.isEmpty();
        }

        /** 面向用户解释「为什么一首都没匹配到」。 */
        public String explain() {
            if (audio == 0) {
                if (scanned == 0) {
                    return "没有扫描到任何文件。\n\n如果音乐放在子文件夹里，"
                            + "请勾选「包含子文件夹（递归）」后重试。";
                }
                return "扫描到 " + scanned + " 个文件，但没有可识别的音频格式。";
            }
            StringBuilder sb = new StringBuilder();
            sb.append("扫描 ").append(audio).append(" 首音频，没有一首匹配成功：\n");
            if (skippedExisting > 0) {
                sb.append("\n· 已有同名 .lrc 跳过：").append(skippedExisting)
                        .append(" 首（勾选「覆盖已有 .lrc」可重试）");
            }
            if (noTitle > 0) {
                sb.append("\n· 认不出歌名：").append(noTitle)
                        .append(" 首（文件名无「歌手 - 歌名」结构且标签为空）");
            }
            if (rejected > 0) {
                sb.append("\n· 找到歌词但没通过校验：").append(rejected).append(" 首");
                if (!rejectNote.isEmpty()) {
                    sb.append("（").append(rejectNote).append("）");
                }
                sb.append("\n　纯文本歌词需勾选「接受无时间轴的纯文本歌词」才会保留");
            }
            if (notFound > 0) {
                sb.append("\n· 所有歌词源都没有：").append(notFound).append(" 首");
                sb.append("\n　已查 LRCLIB / 网易云 / QQ 音乐 / lyrics.ovh 四家");
            }
            if (skippedKnown > 0) {
                sb.append("\n· 按记忆跳过：").append(skippedKnown)
                        .append(" 首（上批已确认查不到 / 已写入，可在「安全网」清除记忆）");
            }
            if (failed > 0) {
                sb.append("\n· 处理出错：").append(failed).append(" 首");
                if (!errorNote.isEmpty()) {
                    sb.append("（").append(errorNote).append("）");
                }
            }
            if (!networkError.isEmpty()) {
                sb.append("\n\n部分源请求失败：").append(networkError)
                        .append("\n歌词已轮询 LRCLIB / 网易云 / QQ 音乐 / lyrics.ovh，")
                        .append("单源不可用不影响其余；若全部失败请检查网络。");
            }
            return sb.toString();
        }
    }

    /** 单首文件的匹配结果（并发执行，各字段只属于自己，最后在主线程合并统计）。 */
    private static final class FileResult {
        Match match;
        boolean audio;
        boolean skippedExisting;
        boolean noTitle;
        boolean rejected;
        boolean notFound;
        boolean skippedKnown;
        boolean failed;
        String note = "";
        String error = "";
        String networkError = "";
    }

    /**
     * 第一阶段：批量查歌词，只返回匹配结果，**不写任何文件**。
     * filenameWeight：文件名权重 0~1，决定用「文件名解析」还是「已有标签」的歌名/歌手，
     * 主用组合查不到时用另一组合再试一次。
     *
     * <p><b>并发</b>：{@link Net#FILE_CONCURRENCY} 路同时查多首。单首内部仍是
     * 「/api/get → /api/search」，LRCLIB 有 350ms 限流，靠 {@link LrcClient} 的票制排队控制，
     * 不会因为并发而被封。写入阶段仍走 {@link #writeMatches} 串行。
     */
    public static FetchResult fetchMatches(final Storage st, final ContentResolver resolver,
                                           List<VFile> audioFiles, final boolean overwrite,
                                           final boolean acceptPlain, final double filenameWeight,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log) {
        return fetchMatches(st, resolver, audioFiles, overwrite, acceptPlain, filenameWeight,
                null, progress, cancel, log);
    }

    /**
     * 同上，但把每首匹配成功的歌词**一产出就放进 {@code sink}** —— 用户中途暂停时，
     * 界面可以直接预览「已获取的部分」而不必等整批跑完。
     *
     * @param sink 可为 null（不需要暂停预览时）
     */
    public static FetchResult fetchMatches(final Storage st, final ContentResolver resolver,
                                           List<VFile> audioFiles, final boolean overwrite,
                                           final boolean acceptPlain, final double filenameWeight,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log) {
        return fetchMatches(st, resolver, audioFiles, overwrite, acceptPlain, filenameWeight,
                sink, progress, cancel, log, null);
    }

    /**
     * 带「匹配记忆」的版本：上批已确认「查不到 / 被拦 / 已写入」的歌直接跳过，不再联网。
     * 传 null 等同于不带记忆。
     */
    public static FetchResult fetchMatches(final Storage st, final ContentResolver resolver,
                                           List<VFile> audioFiles, final boolean overwrite,
                                           final boolean acceptPlain, final double filenameWeight,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log, final BatchMemory memory) {
        return fetchMatches(st, resolver, audioFiles, overwrite, acceptPlain, filenameWeight,
                sink, progress, cancel, log, memory, (BatchSkip) null);
    }

    /**
     * 再带一个 {@link BatchSkip} 的版本：把「按记忆跳过」的歌收集起来，
     * 界面据此给出「重新查询这 N 首」的入口。
     */
    public static FetchResult fetchMatches(final Storage st, final ContentResolver resolver,
                                           List<VFile> audioFiles, final boolean overwrite,
                                           final boolean acceptPlain, final double filenameWeight,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log, final BatchMemory memory,
                                           final BatchSkip skip) {
        return fetchMatches(st, resolver, audioFiles, overwrite, acceptPlain, filenameWeight,
                sink, progress, cancel, log, memory, skip, null);
    }

    /**
     * 带中间态队列、但不关心「按记忆跳过」名单的版本（整理页走这条）。
     */
    public static FetchResult fetchMatches(final Storage st, final ContentResolver resolver,
                                           List<VFile> audioFiles, final boolean overwrite,
                                           final boolean acceptPlain, final double filenameWeight,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log, final BatchMemory memory,
                                           final MatchQueue queue) {
        return fetchMatches(st, resolver, audioFiles, overwrite, acceptPlain, filenameWeight,
                sink, progress, cancel, log, memory, null, queue);
    }

    /**
     * 再带一个中间态队列：上次匹配到、但没写完的歌词，这次直接复用，不再联网。
     *
     * <p>歌词正文本身就比较长（一首几 KB），所以队列按条数封顶（见 {@code MatchQueue}），
     * 用户连续攒几批也不会把内存吃爆。
     */
    public static FetchResult fetchMatches(final Storage st, final ContentResolver resolver,
                                           List<VFile> audioFiles, final boolean overwrite,
                                           final boolean acceptPlain, final double filenameWeight,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log, final BatchMemory memory,
                                           final BatchSkip skip, final MatchQueue queue) {
        final LrcClient client = new LrcClient();
        final FetchResult res = new FetchResult();
        // 去重：重叠授权 / 重复扫描可能让同一个文档出现多次，只处理一次
        final java.util.LinkedHashMap<String, VFile> seen =
                new java.util.LinkedHashMap<String, VFile>();
        for (VFile f : audioFiles) {
            String key = (f.docId == null || f.docId.isEmpty()) ? f.name : f.docId;
            if (!seen.containsKey(key)) {
                seen.put(key, f);
            }
        }
        final List<VFile> deduped = new java.util.ArrayList<VFile>(seen.values());
        final int removed = audioFiles.size() - deduped.size();
        audioFiles = deduped;

        res.scanned = audioFiles.size();
        final int total = audioFiles.size();
        final java.util.concurrent.atomic.AtomicInteger done =
                new java.util.concurrent.atomic.AtomicInteger();

        List<FileResult> parts = Net.mapIndexed(audioFiles, Net.FILE_CONCURRENCY, cancel,
                new Net.IndexedWork<VFile, FileResult>() {
                    @Override
                    public FileResult run(int index, VFile audio) {
                        try {
                            FileResult r = oneFile(st, resolver, client, audio, overwrite,
                                    acceptPlain, filenameWeight, cancel, log, memory, skip, queue);
                            if (sink != null && r != null) {
                                sink.add(index, r.match);
                            }
                            return r;
                        } finally {
                            int d = done.incrementAndGet();
                            if (progress != null) {
                                // 并发下各文件完成顺序不定，只报稳定进度、不报文件名，
                                // 避免日志/状态栏出现「队列乱跳」的观感
                                progress.onProgress(d, total,
                                        "匹配歌词 " + d + "/" + total);
                            }
                        }
                    }
                });

        for (FileResult r : parts) {
            if (r == null) {
                continue;
            }
            if (r.audio) {
                res.audio++;
            }
            if (r.match != null) {
                res.matches.add(r.match);
            }
            if (r.skippedExisting) {
                res.skippedExisting++;
            }
            if (r.noTitle) {
                res.noTitle++;
            }
            if (r.rejected) {
                res.rejected++;
            }
            if (r.notFound) {
                res.notFound++;
            }
            if (r.skippedKnown) {
                res.skippedKnown++;
            }
            if (r.failed) {
                res.failed++;
            }
            if (res.rejectNote.isEmpty() && !r.note.isEmpty()) {
                res.rejectNote = r.note;
            }
            if (res.errorNote.isEmpty() && !r.error.isEmpty()) {
                res.errorNote = r.error;
            }
            if (res.networkError.isEmpty() && !r.networkError.isEmpty()) {
                res.networkError = r.networkError;
            }
        }
        if (cancel != null && cancel.isCancelledNow()) {
            res.stopped = true;
        }

        if (memory != null) {
            memory.save();
        }
        if (queue != null) {
            queue.save();
        }
        if (log != null) {
            if (removed > 0) {
                log.log("歌词匹配：去重 " + removed + " 个重复文件", "info");
            }
            if (res.skippedKnown > 0) {
                log.log("歌词匹配：按记忆跳过 " + res.skippedKnown + " 首（上批已确认无结果或已写入）",
                        "info");
            }
            log.log("歌词匹配：可写 " + res.matches.size() + " 首，音频 " + res.audio
                    + " 首，已有 lrc 跳过 " + res.skippedExisting + " 首", "info");
        }
        return res;
    }

    /** 单首歌词匹配（并发执行，不碰共享可变状态）。 */
    private static FileResult oneFile(Storage st, ContentResolver resolver, LrcClient client,
                                      VFile audio, boolean overwrite, boolean acceptPlain,
                                      double filenameWeight, CancelToken cancel, Logger log,
                                      BatchMemory memory, BatchSkip skip, MatchQueue queue) {
        FileResult r = new FileResult();
        if (!audio.audio()) {
            return r;
        }
        String ext = audio.ext();
        if (!(ext.equals(".mp3") || ext.equals(".flac") || ext.equals(".m4a")
                || ext.equals(".wav") || ext.equals(".ogg") || ext.equals(".opus"))) {
            return r;
        }
        r.audio = true;
        // 记忆优先：上批已确认「四家都没有 / 被校验拦下 / 已写入」的直接跳过
        final String memKey = TagBatch.memKey(audio);
        if (memory != null && memory.shouldSkip(memKey, audio.size, audio.lastModified)) {
            r.skippedKnown = true;
            if (skip != null) {
                skip.addMemory(audio); // 记下来：界面要给「重新查询这 N 首」的入口
            }
            return r;
        }
        try {
            VFile existing = findLrc(st, audio);
            if (existing != null && !overwrite) {
                r.skippedExisting = true;
                return r;
            }
            // 续跑：上次已经匹配到、还没写盘的歌词直接用，省掉四家源的一次查询。
            // 放在「已有 lrc」判定之后 —— 文件已经有了，就不该再拿旧结果去覆盖。
            if (queue != null && !(memory != null && memory.ignoreExisting())) {
                Match rm = fromQueue(queue.take(memKey, audio.size, audio.lastModified), audio);
                if (rm != null) {
                    r.match = rm;
                    if (log != null) {
                        log.log("歌词续跑：沿用上次匹配结果 · " + audio.name, "info");
                    }
                    return r;
                }
            }
            Tags tags = Scanner.readTagsCheap(st, resolver, audio);
            String tagTitle = TextUtil.safeStr(tags.get("title"));
            String tagArtist = TextUtil.safeStr(tags.get("artist"));
            String nameArtist = "";
            String nameTitle = "";
            List<String[]> pairs = NameParser.candidatePairs(audio.stem());
            if (!pairs.isEmpty()) {
                nameArtist = TextUtil.safeStr(pairs.get(0)[0]);
                nameTitle = TextUtil.safeStr(pairs.get(0)[1]);
            }
            // 按权重决定主用组合，另一组合留作二次尝试
            String title = NameWeight.pick(nameTitle, tagTitle, filenameWeight);
            String artist = NameWeight.pick(nameArtist, tagArtist, filenameWeight);
            String altTitle = NameWeight.pickSecondary(nameTitle, tagTitle, filenameWeight);
            String altArtist = NameWeight.pickSecondary(nameArtist, tagArtist, filenameWeight);
            if (title.isEmpty()) {
                r.noTitle = true;
                if (log != null) {
                    log.log("认不出歌名：" + audio.name, "warning");
                }
                return r;
            }
            Double duration = Scanner.durationOf(st, resolver, audio);
            String album = TextUtil.safeStr(tags.get("album"));
            Lookup hit = lookup(client, title, artist, album, duration, acceptPlain, cancel);
            String usedTitle = title;
            String usedArtist = artist;
            if (hit.content.isEmpty() && !altTitle.isEmpty()) {
                Lookup alt = lookup(client, altTitle, altArtist, album, duration, acceptPlain, cancel);
                if (!alt.content.isEmpty()) {
                    hit = alt;
                    usedTitle = altTitle;
                    usedArtist = altArtist;
                } else if (hit.reject.isEmpty()) {
                    hit.reject = alt.reject;
                }
                if (hit.networkError.isEmpty()) {
                    hit.networkError = alt.networkError;
                }
                hit.found = hit.found || alt.found;
            }
            if (!hit.networkError.isEmpty()) {
                r.networkError = hit.networkError;
            }
            if (hit.content.trim().isEmpty()) {
                if (memory != null) {
                    memory.record(memKey, audio.size, audio.lastModified,
                            hit.found ? BatchMemory.REJECTED : BatchMemory.NO_HIT);
                }
                if (hit.found) {
                    r.rejected = true;
                    r.note = hit.reject;
                    if (log != null) {
                        log.log("歌词被质量校验拦下：" + audio.name
                                + "（" + hit.reject + "）", "warning");
                    }
                } else {
                    r.notFound = true;
                    if (log != null) {
                        log.log("未找到歌词：" + audio.name, "info");
                    }
                }
                return r;
            }
            Match m = new Match();
            m.file = audio;
            m.title = usedTitle;
            m.artist = usedArtist;
            m.content = hit.content;
            m.sourceLabel = hit.sourceLabel;
            m.translationLines = hit.translationLines;
            m.simplified = hit.simplified;
            String quality = qualityError(hit.content);
            m.timeline = quality.isEmpty();
            if (!m.timeline) {
                m.note = quality;
                m.selected = false; // 无时间轴的低质量结果默认不写
            }
            r.match = m;
            // 中间态落库：正文一并存下来（几 KB），被杀后重启不必再查四家源
            if (queue != null) {
                java.util.Map<String, String> f = new java.util.LinkedHashMap<String, String>();
                f.put("@content", hit.content);
                f.put("@t", usedTitle);
                f.put("@a", usedArtist);
                f.put("@src", TextUtil.safeStr(hit.sourceLabel));
                f.put("@tl", m.timeline ? "1" : "0");
                f.put("@tr", String.valueOf(m.translationLines));
                f.put("@simp", m.simplified ? "1" : "0");
                f.put("@note", TextUtil.safeStr(m.note));
                queue.put(memKey, audio.size, audio.lastModified, f);
            }
        } catch (Exception e) {
            r.failed = true;
            r.error = TextUtil.shortError(e);
            if (log != null) {
                log.log("歌词匹配失败：" + audio.name + "（" + TextUtil.shortError(e) + "）",
                        "error");
            }
        }
        return r;
    }

    /** 从中间态队列还原一条歌词匹配；正文为空视为无效（当作没命中过）。 */
    private static Match fromQueue(MatchQueue.Item it, VFile audio) {
        if (it == null) {
            return null;
        }
        String content = it.field("@content", "");
        if (content.trim().isEmpty()) {
            return null;
        }
        Match m = new Match();
        m.file = audio;
        m.title = it.field("@t", "");
        m.artist = it.field("@a", "");
        m.content = content;
        m.sourceLabel = it.field("@src", "");
        m.timeline = "1".equals(it.field("@tl", "0"));
        m.note = it.field("@note", "");
        m.simplified = "1".equals(it.field("@simp", "0"));
        try {
            m.translationLines = Integer.parseInt(it.field("@tr", "0").trim());
        } catch (Exception ignored) {
            m.translationLines = 0;
        }
        // 与首次匹配同一套默认勾选规则：没有时间轴的纯文本默认不写
        m.selected = m.timeline;
        m.resumed = true;
        return m;
    }

    /**
     * 第二阶段：把用户确认过的匹配结果写入同名 .lrc，embed=true 时同时嵌入音频标签。
     * 返回 {written, skipped, failed}。
     */
    public static int[] writeMatches(Storage st, ContentResolver resolver,
                                     android.content.Context ctx, List<Match> matches,
                                     boolean overwrite, boolean embed,
                                     Progress progress, CancelToken cancel, Logger log) {
        return writeMatches(st, resolver, ctx, matches, overwrite, embed, progress, cancel, log, null);
    }

    /** 同上，写成功后把该文件记进匹配记忆（下一批直接跳过）。 */
    public static int[] writeMatches(Storage st, ContentResolver resolver,
                                     android.content.Context ctx, List<Match> matches,
                                     boolean overwrite, boolean embed,
                                     Progress progress, CancelToken cancel, Logger log,
                                     BatchMemory memory) {
        return writeMatches(st, resolver, ctx, matches, overwrite, embed, progress, cancel, log,
                memory, null);
    }

    /** 同上，并同步中间态队列（写完 / 跳过 / 失败的销账，剩下的留待续跑）。 */
    public static int[] writeMatches(Storage st, ContentResolver resolver,
                                     android.content.Context ctx, List<Match> matches,
                                     boolean overwrite, boolean embed,
                                     Progress progress, CancelToken cancel, Logger log,
                                     BatchMemory memory, MatchQueue queue) {
        int written = 0;
        int skipped = 0;
        int failed = 0;
        int done = 0;
        for (Match m : matches) {
            done++;
            if (cancel != null && cancel.isCancelled()) {
                break;
            }
            if (progress != null) {
                progress.onProgress(done, matches.size(), "写入歌词：" + m.file.name);
            }
            if (!m.selected) {
                skipped++;
                if (queue != null) {
                    queue.mark(TagBatch.memKey(m.file), MatchQueue.SKIPPED);
                }
                continue;
            }
            try {
                String err = writeLrc(st, m.file, m.content, overwrite, log);
                if (err.isEmpty()) {
                    written++;
                    if (memory != null) {
                        memory.markDone(TagBatch.memKey(m.file), m.file.size, m.file.lastModified);
                    }
                    if (queue != null) {
                        queue.mark(TagBatch.memKey(m.file), MatchQueue.WRITTEN);
                    }
                    if (embed) {
                        String embedErr = embedLyrics(st, resolver, ctx, m.file, m.content, log);
                        if (!embedErr.isEmpty() && log != null) {
                            log.log("歌词嵌入标签失败：" + m.file.name + "（" + embedErr + "）",
                                    "warning");
                        }
                    }
                } else {
                    failed++;
                    if (log != null) {
                        log.log("歌词写入失败：" + m.file.name + "（" + err + "）", "error");
                    }
                    if (queue != null) {
                        queue.mark(TagBatch.memKey(m.file), MatchQueue.FAILED);
                    }
                }
            } catch (Exception e) {
                failed++;
                if (log != null) {
                    log.log("歌词处理失败：" + m.file.name + "（" + TextUtil.shortError(e) + "）",
                            "error");
                }
                if (queue != null) {
                    queue.mark(TagBatch.memKey(m.file), MatchQueue.FAILED);
                }
            }
        }
        if (memory != null) {
            memory.save();
        }
        if (queue != null) {
            queue.clearFinished();
        }
        return new int[]{written, skipped, failed};
    }

    /** 预览用：取前 n 行（避免弹窗过长）。 */
    public static String excerpt(String content, int maxLines) {
        if (content == null) {
            return "";
        }
        String[] lines = content.replace("\r\n", "\n").split("\n");
        StringBuilder sb = new StringBuilder();
        int shown = 0;
        for (String line : lines) {
            if (shown >= maxLines) {
                sb.append("…（共 ").append(lines.length).append(" 行）");
                break;
            }
            sb.append(line).append('\n');
            shown++;
        }
        return sb.toString();
    }

    /**
     * 把歌词写进音频标签：MP3 → USLT 帧，FLAC → LYRICS 字段。
     * 走 TagTransaction 事务层（副本写入 + 校验 + 回读），失败原文件不动。
     * record=false：歌词体积大，不写入 journal，保持撤销日志精简。
     */
    public static String embedLyrics(Storage st, ContentResolver resolver,
                                     android.content.Context ctx, VFile audio,
                                     String content, Logger log) {
        String ext = audio.ext();
        if (!(ext.equals(".mp3") || ext.equals(".flac"))) {
            return ""; // 其余格式不支持嵌入，只写 .lrc 即可
        }
        String text = content == null ? "" : content.trim();
        if (text.isEmpty()) {
            return "歌词为空";
        }
        Map<String, String> updates = new HashMap<String, String>();
        updates.put(Tags.LYRICS, text);
        return TagTransaction.apply(st, resolver, ctx, audio, updates, false, "", log);
    }

    /** 查找同基名 .lrc；不存在返回 null。 */
    public static VFile findLrc(Storage st, VFile audio) {
        if (audio.parentId == null) {
            return null;
        }
        VFile dir = st.stat(audio.parentId, null);
        if (dir == null) {
            return null;
        }
        String lrcName = audio.stem() + ".lrc";
        return st.findChild(dir, lrcName);
    }

    /** 读取 .lrc 文本（UTF-8，去掉 BOM）；失败返回空串。 */
    public static String readLrc(Storage st, VFile lrcFile) {
        if (lrcFile == null) {
            return "";
        }
        File tmp = null;
        try {
            tmp = File.createTempFile("mo_lrcread_", ".lrc");
            st.copyToLocal(lrcFile, tmp);
            byte[] body = new byte[(int) tmp.length()];
            java.io.FileInputStream in = new java.io.FileInputStream(tmp);
            int read = 0;
            while (read < body.length) {
                int n = in.read(body, read, body.length - read);
                if (n <= 0) {
                    break;
                }
                read += n;
            }
            in.close();
            String text = new String(body, 0, read, StandardCharsets.UTF_8);
            if (text.startsWith("\uFEFF")) {
                text = text.substring(1);
            }
            return text;
        } catch (Exception e) {
            return "";
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
    }

    /** 写入同名 .lrc（UTF-8）；覆盖前已有文件将保留 .lrc.bak。返回 "" 或错误。 */
    public static String writeLrc(Storage st, VFile audio, String content,
                                  boolean overwrite, Logger log) {
        try {
            VFile dir = st.stat(audio.parentId, null);
            if (dir == null) {
                return "找不到所在目录";
            }
            String lrcName = audio.stem() + ".lrc";
            VFile existing = st.findChild(dir, lrcName);
            if (existing != null && !overwrite) {
                return "已存在 .lrc";
            }
            byte[] body = content.replace("\r\n", "\n").replace("\n", "\r\n")
                    .getBytes(StandardCharsets.UTF_8);
            if (existing != null) {
                // 覆盖前备份旧内容为 .lrc.bak
                File old = File.createTempFile("mo_lrcold_", ".lrc");
                st.copyToLocal(existing, old);
                // 备份名固定为 xxx.lrc.bak。注意：createFile 传 mime=text/plain 时，
                // 部分系统会按 mime 给名字补一个 .txt（变成 xxx.lrc.bak.txt）——
                // 这就是「清理完之后一堆 .lrc.bak.txt」的来源（v0.1.60）。
                // 这里建完立刻改名回 xxx.lrc.bak；找不到也兼容旧版本留下的 .bak.txt。
                VFile bak = st.findChild(dir, lrcName + ".bak");
                if (bak == null) {
                    bak = st.findChild(dir, lrcName + ".bak.txt");
                }
                if (bak == null) {
                    bak = st.createFile(dir, lrcName + ".bak", "text/plain");
                    if (bak != null && !bak.name.equals(lrcName + ".bak")) {
                        st.rename(bak, lrcName + ".bak");
                        VFile fixed = st.findChild(dir, lrcName + ".bak");
                        if (fixed != null) {
                            bak = fixed;
                        }
                    }
                }
                if (bak != null) {
                    st.writeFromLocal(bak, old);
                }
                //noinspection ResultOfMethodCallIgnored
                old.delete();
                st.writeFromLocal(existing, toTemp(st, content));
                return "";
            }
            VFile created = st.createFile(dir, lrcName, "text/plain");
            if (created == null) {
                return "创建 .lrc 失败";
            }
            File tmp = File.createTempFile("mo_lrc_", ".lrc");
            java.io.FileOutputStream out = new java.io.FileOutputStream(tmp);
            out.write(body);
            out.close();
            st.writeFromLocal(created, tmp);
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            if (!created.name.equals(lrcName)) {
                st.rename(created, lrcName);
            }
            return "";
        } catch (Exception e) {
            return TextUtil.shortError(e);
        }
    }

    private static File toTemp(Storage st, String content) throws Exception {
        File tmp = File.createTempFile("mo_lrc_", ".lrc");
        java.io.FileOutputStream out = new java.io.FileOutputStream(tmp);
        out.write(content.replace("\r\n", "\n").replace("\n", "\r\n")
                .getBytes(StandardCharsets.UTF_8));
        out.close();
        return tmp;
    }
}
