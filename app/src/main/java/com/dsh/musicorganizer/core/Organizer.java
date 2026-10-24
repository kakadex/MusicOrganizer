package com.dsh.musicorganizer.core;

import android.content.ContentResolver;

import com.dsh.musicorganizer.net.MbClient;
import com.dsh.musicorganizer.net.Sources;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 自动整理 —— 对应 Python 版 RecognitionEngine + organize 流程。
 *
 * 三条红线保持不变：
 *   R-01 歌名不可当歌手（artist-credit 严格取）
 *   R-02 返回名必须可信（7 条合理性校验）
 *   R-03 组内配对不可拆（音频 + 歌词原子移动，失败回滚）
 */
public final class Organizer {

    /**
     * 连续多少组「联网零候选」后本轮停止联网。
     * 定 30：纯歌名的库一轮也就几十组，真断网时最多白跑 30 组就停；
     * 而正常库（多数歌靠标签/文件名就能识别）几乎不会触发。
     */
    private static final int NET_EMPTY_RUN_LIMIT = 30;

    private Organizer() {
    }

    public static class Options {
        public boolean recursive = false;
        public boolean skipArtistDirs = true;
        public boolean includeUnrecognized = false;
        public boolean fastMode = true;
        public boolean useNetwork = true;
        public boolean dryRun = false;
        /**
         * 未识别的组是否移入「未识别」目录。
         * **默认关闭**：识别不准时把几百组倒进一个扁平目录，等于把曲库结构毁了
         * （v0.1.15 实测：539 组被搬进 未识别/，用户只能手工找回）。
         */
        public boolean moveUnrecognized = false;
        /** 是否启用国内召回源（网易/QQ/酷狗/酷我/咪咕）参与识别 */
        public boolean useCnSources = true;
        /** 联网召回的最低置信度（文件名已给出歌手时放宽，纯歌名时收紧） */
        public double netMinConfidence = 0.30;
        /** 目标目录结构，见 {@link Layout}（默认 艺人/，与历史行为一致）。 */
        public int layout = Layout.ARTIST;
        /**
         * 记录移动日志用的 Context（v0.1.39）。
         * 为空时不记（比如桌面诊断工具），不影响整理本身。
         */
        public android.content.Context ctx;
    }

    public static class Result {
        public int ok;
        public int skipped;
        public int failed;
        public int unrecognized;
        /** 列表过期导致源文件已不在原位置的组数（记为跳过，不算失败）。 */
        public int stale;
        /**
         * 连续「联网一个候选都没有」的组数。达到 {@link #NET_EMPTY_RUN_LIMIT} 后本轮不再联网，
         * 避免整库真的断网时每组都去撞八家接口。
         */
        public int netEmptyRun;
        /** 未识别原因计数：无歌手线索 / 联网无候选 / 候选不可信 */
        public final Map<String, Integer> unrecognizedWhy = new HashMap<String, Integer>();
        public final List<String> errors = new ArrayList<String>();
    }

    /** 识别结果：成功时 {@code artist} 非空，失败时 {@code why} 说明原因。 */
    public static class Pick {
        public final String artist;
        public final String why;

        Pick(String artist, String why) {
            this.artist = artist;
            this.why = why;
        }
    }

    /**
     * 已有歌手目录索引 —— 同一艺人不同写法不该拆成多个目录。
     *
     * <p>实测 v0.1.16 预览：877 组落进 587 个目录，其中
     * `示例乐队 / 示例乐队 &amp; The Band / 示例乐队 And The Band` 三个目录并存，
     * 某首歌因为文件名是「歌名-歌手」被归到了 `歌名/` 目录。
     * 归一键把 `&amp; / 、 / ， / +` 统一成 `and`，就能让写法差异落到同一目录。
     */
    public static class Folders {
        private final Map<String, String> byKey = new HashMap<String, String>();

        public void put(String folder) {
            String key = key(folder);
            if (!key.isEmpty() && !byKey.containsKey(key)) {
                byKey.put(key, folder);
            }
        }

        /** 已有同义目录名；没有返回 null。 */
        public String match(String folder) {
            return byKey.get(key(folder));
        }

        /** 这个名字是否已经是一个目录（用于「哪个候选才是歌手」的判断）。 */
        public boolean contains(String name) {
            return byKey.containsKey(key(name));
        }

        public int size() {
            return byKey.size();
        }

        /** NFKC + 小写 + 去空白 + 连接符统一（实现见 {@link ArtistRules#folderKey}）。 */
        public static String key(String s) {
            return ArtistRules.folderKey(s);
        }
    }

    // ------------------------------------------------------------------
    // 识别
    // ------------------------------------------------------------------

    /** 组内识别：返回歌手名；失败返回 null（保留原位 / 进 未识别 目录）。 */
    public static String identifyGroup(Storage st, ContentResolver resolver,
                                       MbClient mb, TrackGroup group, Options o,
                                       Logger log, CancelToken cancel) {
        return identifyGroup(st, resolver, mb, group, o, log, cancel, null, null);
    }

    /**
     * 带上下文的组内识别。
     *
     * @param folders 已有歌手目录（可为 null）：用来纠正「歌名-歌手」这类歌名在前、
     *                歌手在后的文件名 —— 哪一半已经是目录名，哪一半才是歌手。
     * @param result  未识别原因统计（可为 null）。
     */
    public static String identifyGroup(Storage st, ContentResolver resolver,
                                       MbClient mb, TrackGroup group, Options o,
                                       Logger log, CancelToken cancel,
                                       Folders folders, Result result) {
        return identifyGroupDetail(st, resolver, mb, group, o, cancel, folders, result).artist;
    }

    /** 同 {@link #identifyGroup}，但返回带失败原因的 {@link Pick}。 */
    public static Pick identifyGroupDetail(Storage st, ContentResolver resolver,
                                           MbClient mb, TrackGroup group, Options o,
                                           CancelToken cancel, Folders folders, Result result) {
        String originalStem = group.basename;
        List<NameParser.Candidate> ordered = new ArrayList<NameParser.Candidate>();
        String tagTitle = "";
        String tagArtist = "";

        // 1) 标签候选（最多读前 2 个音频）
        int tagReads = 0;
        for (VFile audio : group.audio) {
            if (tagReads >= 2) {
                break;
            }
            tagReads++;
            Tags tags = Scanner.readTagsCheap(st, resolver, audio);
            String tTitle = TextUtil.safeStr(tags.get("title"));
            String tArtist = TextUtil.safeStr(tags.get("artist"));
            if (tagTitle.isEmpty() && tagArtist.isEmpty()) {
                tagTitle = tTitle;
                tagArtist = tArtist;
            }
            // 「华语群星 / 群星 / Various Artists」是占位标签，不能当歌手目录
            if (ArtistRules.isGenericArtist(tArtist)) {
                tArtist = "";
            }
            if (!tTitle.isEmpty() && !tArtist.isEmpty()) {
                NameParser.Candidate c = new NameParser.Candidate(tArtist, tTitle, "标签");
                if (!ordered.contains(c)) {
                    ordered.add(c);
                }
            } else if (!tTitle.isEmpty()) {
                NameParser.Candidate c = new NameParser.Candidate(null, tTitle, "标签标题");
                if (!ordered.contains(c)) {
                    ordered.add(c);
                }
            }
        }
        // 2) 文件名候选
        List<NameParser.Candidate> fromName = NameParser.nameCandidates(originalStem);
        for (NameParser.Candidate c : fromName) {
            if (!ordered.contains(c)) {
                ordered.add(c);
            }
        }

        // 3) 先试「歌手已经是现有目录」的候选：
        //    「歌名-歌手」里后半段才是歌手，但默认顺序先取了前半段。
        //
        //    **这一步不再联网校验**（v0.1.55）：目录本身就是「前面若干组确认过的歌手」，
        //    再问一次 MusicBrainz 纯属重复劳动 —— 而 MB 有 1 秒一条的硬性限流，
        //    1212 组就是 20 分钟。实测日志里「中途突然变快」正是 MB 被限流后跳过校验的
        //    结果，说明这个校验对速度影响巨大、对准确率贡献很小（歌手已经在目录里了）。
        if (folders != null) {
            for (NameParser.Candidate candidate : ordered) {
                if (candidate.artist == null || !folders.contains(candidate.artist)) {
                    continue;
                }
                if (isSameName(candidate.artist, candidate.title)) {
                    continue;
                }
                if (passesRule(candidate, originalStem)) {
                    return new Pick(ArtistRules.normalizeCandidate(candidate.artist), null);
                }
            }
        }

        // 3.5) 标签与文件名给出同一个歌手 —— 两个独立来源互相印证，同样不必联网
        if (!tagArtist.isEmpty() && !tagTitle.isEmpty()) {
            for (NameParser.Candidate candidate : ordered) {
                if (candidate.artist == null || candidate.title == null) {
                    continue;
                }
                if (!isSameName(candidate.title, tagTitle)) {
                    continue;
                }
                if (!TextUtil.normCompare(ArtistRules.normalizeCandidate(candidate.artist))
                        .equals(TextUtil.normCompare(ArtistRules.normalizeCandidate(tagArtist)))) {
                    continue;
                }
                if (passesRule(candidate, originalStem)) {
                    return new Pick(ArtistRules.normalizeCandidate(candidate.artist), null);
                }
            }
        }

        // 4) 逐候选识别（到这一步才真的问网络）
        for (NameParser.Candidate candidate : ordered) {
            if (cancel != null && cancel.isCancelled()) {
                return new Pick(null, "已取消");
            }
            String artist = identifyCandidate(mb, candidate, originalStem, o);
            if (artist != null && ArtistRules.isReasonableArtistReturn(
                    artist, candidate.title, originalStem,
                    candidate.artist == null ? null : candidate.artist)) {
                return new Pick(artist, null);
            }
        }

        // 5) 规则都失败 → 八源联网召回。
        //    只查 MusicBrainz 时中文歌几乎全落空（实测 913 组里 36 组「成都」「早安隆回」
        //    这类纯歌名全部识别不出），而本地已接好的网易/QQ/酷狗/酷我/咪咕/ iTunes 都有。
        //
        //    注意：这里**不能**拿 mb.isOffline() 当门槛。它是 MusicBrainz 连续失败三次后
        //    置位的一次性开关（会话内不会自愈），而国内源走的是完全不同的域名 ——
        //    MB 被限流时网易/QQ 照样能用。2026-10-22 23:25 的日志就是这么翻车的：
        //    36 组全部记成「无歌手线索」，一次联网都没发生。
        if (o != null && o.useNetwork && mb != null) {
            if (result != null && result.netEmptyRun >= NET_EMPTY_RUN_LIMIT) {
                bump(result, "联网连续无候选（本轮已停查）");
                return new Pick(null, "联网连续无候选（本轮已停查）");
            }
            String fromNet = identifyBySources(st, resolver, mb, group, o, cancel,
                    originalStem, tagTitle, tagArtist, folders);
            if (fromNet != null) {
                if (result != null) {
                    result.netEmptyRun = 0;
                }
                return new Pick(fromNet, null);
            }
            if (result != null) {
                // 连续空手才计数：中途命中过一首就清零，避免整库真的没网时白跑
                result.netEmptyRun++;
            }
            bump(result, "联网无候选");
            return new Pick(null, "联网无候选");
        }
        bump(result, "无歌手线索");
        return new Pick(null, "无歌手线索");
    }

    /**
     * 候选自洽性检查（不发网络请求）：歌手与歌名都不为空、彼此不同、且通过合理性判定。
     * 相当于 {@code identifyCandidate} 里 {@code ruleOk} 那一段，抽出来给「免联网」分支共用。
     */
    private static boolean passesRule(NameParser.Candidate candidate, String originalStem) {
        String artist = ArtistRules.normalizeCandidate(
                candidate.artist == null ? "" : candidate.artist);
        String title = NameParser.stripNameNoise(candidate.title == null ? "" : candidate.title);
        if (ArtistRules.isGenericArtist(artist)) {
            return false;
        }
        return !artist.isEmpty() && !title.isEmpty()
                && !artist.equals(title)
                && ArtistRules.isReasonableArtistReturn(artist, title, originalStem, null);
    }

    private static void bump(Result result, String why) {
        if (result == null) {
            return;
        }
        Integer n = result.unrecognizedWhy.get(why);
        result.unrecognizedWhy.put(why, n == null ? 1 : n + 1);
    }

    private static boolean isSameName(String a, String b) {
        String x = ArtistRules.normalizeCandidate(a == null ? "" : a);
        String y = NameParser.stripNameNoise(b == null ? "" : b);
        return !x.isEmpty() && TextUtil.normCompare(x).equals(TextUtil.normCompare(y));
    }

    /**
     * 八源联网召回歌手（只为了拿 artist，不写标签）。
     *
     * <p>候选按置信度排序，逐个校验「歌名对得上 + 歌手可信」；
     * 纯歌名（文件名没给歌手）时门槛抬到 0.40，避免「太阳」「嘉宾」这类同名歌张冠李戴。
     */
    private static String identifyBySources(Storage st, ContentResolver resolver, MbClient mb,
                                            TrackGroup group, Options o, CancelToken cancel,
                                            String originalStem, String tagTitle,
                                            String tagArtist, Folders folders) {
        if (cancel != null && cancel.isCancelled()) {
            return null;
        }
        Sources.Query q = new Sources.Query();
        q.filenameCandidates.addAll(NameParser.candidatePairs(originalStem));
        q.embeddedTags.put("title", tagTitle == null ? "" : tagTitle);
        q.embeddedTags.put("artist",
                ArtistRules.isGenericArtist(tagArtist) ? "" : (tagArtist == null ? "" : tagArtist));
        q.useCnSources = o.useCnSources;
        List<Sources.Candidate> cands;
        try {
            cands = Sources.aggregate(mb, q, null, cancel);
        } catch (Exception e) {
            return null;
        }
        if (cands == null || cands.isEmpty()) {
            return null;
        }
        String[] pair = q.filenameCandidates.isEmpty() ? new String[]{"", ""}
                : q.filenameCandidates.get(0);
        String expected = ArtistRules.normalizeCandidate(pair[0]);
        if (ArtistRules.isGenericArtist(expected)) {
            expected = "";
        }
        double minConf = expected.isEmpty()
                ? Math.max(o.netMinConfidence, 0.40) : o.netMinConfidence;
        List<String> acceptable = new ArrayList<String>();
        for (Sources.Candidate c : cands) {
            if (c.confidence < minConf || acceptable.size() >= 6) {
                continue;
            }
            String title = NameParser.stripNameNoise(c.title == null ? "" : c.title);
            if (title.isEmpty() || !titleMatches(title, pair[1], tagTitle)) {
                continue;
            }
            String artist = ArtistRules.normalizeCandidate(c.artist == null ? "" : c.artist);
            if (ArtistRules.isGenericArtist(artist)) {
                continue;
            }
            if (!ArtistRules.isReasonableArtistReturn(artist, title, originalStem,
                    expected.isEmpty() ? null : expected)) {
                continue;
            }
            acceptable.add(artist);
        }
        if (acceptable.isEmpty()) {
            return null;
        }
        // ① 已有目录优先：拼音写法的艺人应该落回已有的中文目录，而不是新建一个拼音目录
        if (folders != null) {
            for (String artist : acceptable) {
                String canonical = folders.match(artist);
                if (canonical != null) {
                    return canonical;
                }
            }
        }
        // ② 中文歌优先中文名：iTunes/Deezer 会把「成都」的歌手写成 Lei Zhao
        if (TextUtil.containsChinese(originalStem)) {
            for (String artist : acceptable) {
                if (TextUtil.containsChinese(artist)) {
                    return artist;
                }
            }
        }
        return acceptable.get(0);
    }

    /** 联网结果歌名与本地歌名是否对得上。 */
    private static boolean titleMatches(String returned, String fromName, String fromTag) {
        String ret = TextUtil.normCompare(returned);
        for (String local : new String[]{fromName, fromTag}) {
            String exp = TextUtil.normCompare(NameParser.stripNameNoise(local == null ? "" : local));
            if (exp.isEmpty()) {
                continue;
            }
            if (exp.equals(ret) || exp.contains(ret) || ret.contains(exp)) {
                return true;
            }
            if (TextUtil.ratio(exp, ret) >= 0.72) {
                return true;
            }
        }
        return false;
    }

    /** 单候选识别：快速模式直接取文件名分隔符；否则先联网校验，联网无果再回退文件名。 */
    public static String identifyCandidate(MbClient mb, NameParser.Candidate candidate,
                                           String originalStem, Options o) {
        String artistSide = ArtistRules.normalizeCandidate(
                candidate.artist == null ? "" : candidate.artist);
        String titleSide = NameParser.stripNameNoise(candidate.title == null ? "" : candidate.title);
        if (ArtistRules.isGenericArtist(artistSide)) {
            artistSide = "";
        }

        // 文件名/标签给出的歌手是否通过 7 条合理性校验（R-01/R-02）
        boolean ruleOk = !artistSide.isEmpty() && !titleSide.isEmpty()
                && !artistSide.equals(titleSide)
                && ArtistRules.isReasonableArtistReturn(artistSide, titleSide, originalStem, null);

        if (o.fastMode && ruleOk) {
            return artistSide;
        }
        if (!titleSide.isEmpty() && o.useNetwork && !mb.isOffline()) {
            List<Map<String, Object>> hits = mb.searchRecordings(
                    titleSide, artistSide, 8);
            Map<String, Object> hit = bestHit(hits, titleSide, artistSide, originalStem);
            if (hit != null) {
                return String.valueOf(hit.get("artist"));
            }
        }
        // 联网没结果就回退文件名结论 —— 否则「关掉快速模式」等于「中文歌一律识别失败」，
        // 会把大量本来正确的组打成未识别（v0.1.15 实测 711 组里 659 组本可由规则识别）。
        return ruleOk ? artistSide : null;
    }

    private static Map<String, Object> bestHit(List<Map<String, Object>> hits,
                                               String title, String expectedArtist,
                                               String originalStem) {
        String exp = TextUtil.normCompare(NameParser.stripNameNoise(title));
        for (Map<String, Object> hit : hits) {
            String returnedArtist = String.valueOf(hit.get("artist"));
            String returnedTitle = String.valueOf(hit.get("title"));
            String ret = TextUtil.normCompare(returnedTitle);
            boolean titleOk;
            if (exp.isEmpty() || ret.isEmpty()) {
                titleOk = false;
            } else if (exp.equals(ret) || exp.contains(ret) || ret.contains(exp)) {
                titleOk = true;
            } else {
                titleOk = TextUtil.ratio(exp, ret) >= 0.62;
            }
            if (!titleOk) {
                continue;
            }
            if (!ArtistRules.isReasonableArtistReturn(
                    returnedArtist, title, originalStem,
                    expectedArtist == null || expectedArtist.isEmpty() ? null : expectedArtist)) {
                continue;
            }
            return hit;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // 整理主流程
    // ------------------------------------------------------------------

    public static Result organize(Storage st, ContentResolver resolver, MbClient mb,
                                  VFile root, List<TrackGroup> groups, Options o,
                                  Progress progress, CancelToken cancel, Logger log) {
        Result result = new Result();
        int total = groups.size();
        // 一次整理 = 一个批次，撤销时整批搬回
        final String moveBatch = System.currentTimeMillis() + "-mv";
        final String moveTime = new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss",
                java.util.Locale.US).format(new java.util.Date());
        final List<MoveLog.Record> moves = new ArrayList<MoveLog.Record>();
        int done = 0;
        int unrecLogged = 0;
        VFile unrecognizedDir = null;
        Map<String, Set<String>> dirNames = new HashMap<String, Set<String>>();
        // 目录 docId → (子目录名 → VFile)：避免每组都重新枚举根目录（O(n²) 的根源）
        Map<String, Map<String, VFile>> dirIndex = new HashMap<String, Map<String, VFile>>();

        // 列表有可能是「上次扫描」恢复的 —— 那时文件已被上一轮整理搬走，
        // 不剔除就会对同一个文件反复报「移动失败」（v0.1.15 实测 999 条）。
        Set<String> rootNames = null;
        if (root != null) {
            try {
                rootNames = new HashSet<String>(namesOf(st, root, dirNames));
            } catch (Exception e) {
                rootNames = null;
            }
        }

        // 已有歌手目录 → 同义写法合并（示例乐队 / 示例乐队 & The Band / 示例乐队 And The Band）
        // 以及「歌名-歌手」这类顺序纠错。列表恢复后 root 里可能已经有上一次整理出的目录。
        Folders folders = new Folders();
        if (root != null) {
            try {
                for (VFile c : st.children(root)) {
                    if (c.dir) {
                        folders.put(c.name);
                    }
                }
            } catch (Exception ignored) {
                // 拿不到目录清单就退化成「不合并」，不影响主流程
            }
        }

        log.log("整理开始：" + total + " 组（目录结构=" + Layout.label(o.layout)
                + "，快速模式=" + (o.fastMode ? "开" : "关")
                + "，联网=" + (o.useNetwork ? "开" : "关")
                + "，未识别" + (o.moveUnrecognized ? "移入未识别/" : "保留原位")
                + (o.dryRun ? "，仅预览" : "") + "）", "info");
        if (o.useNetwork && mb != null && mb.isOffline()) {
            // 以前这种情况一行都不写，用户只能看到「无歌手线索」，根本猜不到是 MB 被限流
            log.log("MusicBrainz 连续失败已被暂停，本轮改用国内源（网易 / QQ / 酷狗 / 酷我 / 咪咕）兜底",
                    "warning");
        }

        for (TrackGroup group : groups) {
            if (cancel != null && cancel.isCancelled()) {
                log.log("已取消（完成 " + done + "/" + total + "）", "warning");
                break;
            }
            done++;
            if (progress != null) {
                progress.onProgress(done, total, group.displayName());
            }
            if (rootNames != null && isStale(group, root, rootNames)) {
                result.stale++;
                if (result.stale <= 3) {
                    log.log("跳过（列表过期，文件已不在原目录）：" + group.displayName(), "warning");
                }
                continue;
            }
            Pick pick = identifyGroupDetail(st, resolver, mb, group, o, cancel, folders, result);
            String artist = pick.artist;
            if (artist == null || artist.trim().isEmpty()) {
                result.unrecognized++;
                if (o.dryRun || !o.moveUnrecognized) {
                    if (unrecLogged < 40) {
                        log.log("未识别" + (o.moveUnrecognized ? "：" : "（保留原位）：")
                                + group.displayName()
                                + (pick.why == null ? "" : "（" + pick.why + "）"), "warning");
                        unrecLogged++;
                    }
                    continue;
                }
                try {
                    if (unrecognizedDir == null) {
                        unrecognizedDir = st.ensureDir(root, TextUtil.UNRECOGNIZED_DIR);
                    }
                    int moved = moveGroup(st, group, unrecognizedDir, log, dirNames,
                            moveBatch, moveTime, moves);
                    if (moved > 0) {
                        log.log("未识别 → 未识别/：" + group.displayName(), "warning");
                    } else {
                        result.failed++;
                    }
                } catch (Exception e) {
                    result.failed++;
                    result.errors.add(group.basename + "：" + TextUtil.shortError(e));
                }
                continue;
            }
            String folder = simplifyArtistFolder(artist);
            if (folder.equalsIgnoreCase(TextUtil.UNRECOGNIZED_DIR)) {
                folder = folder + "_歌手";
            }
            // 同一艺人不同写法落到同一个目录：示例乐队 & The Band / 示例乐队 And The Band
            String reused = folders.match(folder);
            if (reused != null) {
                folder = reused;
            } else {
                folders.put(folder);
            }
            // 目录结构：艺人 / 艺人-专辑 / 平铺（专辑来自标签，仅需要时读）
            String rel = Layout.path(o.layout, folder, albumOf(st, resolver, group, o));
            if (o.dryRun) {
                result.ok++;
                log.log("预览 → " + (rel.isEmpty() ? "" : rel + "/") + group.displayName(), "info");
                continue;
            }
            try {
                VFile targetDir = ensurePath(st, root, rel, dirIndex, dirNames);
                int moved = moveGroup(st, group, targetDir, log, dirNames, moveBatch, moveTime,
                        moves);
                if (moved > 0) {
                    result.ok++;
                    log.log("已归位 → " + folder + "/：" + group.displayName(), "success");
                } else {
                    result.skipped++;
                }
            } catch (Exception e) {
                result.failed++;
                result.errors.add(group.basename + "：" + TextUtil.shortError(e));
                log.log("归位失败：" + group.basename + "（" + TextUtil.shortError(e) + "）", "error");
            }
        }

        if (result.stale > 0) {
            log.log("有 " + result.stale + " 组已不在列表记录的目录里（列表过期），已跳过。"
                    + "请在「库」页重新扫描后再整理。", "warning");
        }
        if (result.unrecognized > 0) {
            StringBuilder sb = new StringBuilder("未识别 " + result.unrecognized + " 组");
            if (!result.unrecognizedWhy.isEmpty()) {
                sb.append("（");
                boolean first = true;
                for (Map.Entry<String, Integer> e : result.unrecognizedWhy.entrySet()) {
                    if (!first) {
                        sb.append("，");
                    }
                    sb.append(e.getKey()).append(" ").append(e.getValue());
                    first = false;
                }
                sb.append("）");
            }
            sb.append("，保留原位");
            sb.append(o.moveUnrecognized && !o.dryRun ? "" : "（未移动）");
            sb.append("。");
            log.log(sb.toString(), "warning");
        }
        if (result.netEmptyRun >= NET_EMPTY_RUN_LIMIT) {
            log.log("连续 " + result.netEmptyRun + " 组联网都没有候选，本轮已提前停止查询；"
                    + "网络恢复后重新整理即可。", "warning");
        }
        // 兜底清理「搬走了但源文件还在」的残留（v0.1.58）。
        // 部分系统（实测 MIUI）的 moveDocument 实际是「复制 + 删除」，删除失败时
        // 仍然返回新 URI —— 表现出来就是「整理完根目录多出一堆重复文件」。
        // 这里按「搬出去的目录」分组，每个目录只列一次，把还留在原地的同名文件删掉。
        if (!o.dryRun && !moves.isEmpty()) {
            int leftover = cleanLeftovers(st, moves, log);
            if (leftover > 0) {
                log.log("已清理 " + leftover + " 个「搬走后仍留在原目录」的残留文件", "warning");
            }
        }

        // 移动日志：撤销时靠它整批搬回原位（只有真移动了才写）
        if (!o.dryRun && o.ctx != null && !moves.isEmpty()) {
            if (MoveJournal.append(o.ctx, moves)) {
                log.log("已记录本次整理：搬动 " + moves.size() + " 个文件，"
                        + "可在「安全网 → 撤销上次整理」搬回原位", "info");
            } else {
                log.log("整理完成，但移动记录写入失败（撤销将不可用）", "warning");
            }
        }
        return result;
    }

    /** 组内主音频已不在记录的父目录里 → 这份列表过期了。 */
    private static boolean isStale(TrackGroup group, VFile root, Set<String> rootNames) {
        if (root == null) {
            return false;
        }
        List<VFile> files = group.allFiles();
        for (VFile f : files) {
            if (f.parentId != null && f.parentId.equals(root.docId) && !rootNames.contains(f.name)) {
                return true;
            }
        }
        return false;
    }

    /** 目录内的名字集合（缓存，避免每个文件都去 IPC 枚举一遍）。 */
    private static Set<String> namesOf(Storage st, VFile dir,
                                       Map<String, Set<String>> cache) {
        Set<String> set = cache.get(dir.docId);
        if (set == null) {
            set = new HashSet<String>();
            for (VFile c : st.children(dir)) {
                set.add(c.name);
            }
            cache.put(dir.docId, set);
        }
        return set;
    }

    /** 整组移动（音频 + 歌词同基名）；单文件失败继续其余，失败带原因。 */
    private static int moveGroup(Storage st, TrackGroup group, VFile targetDir, Logger log,
                                 Map<String, Set<String>> dirNames, String batchId, String time,
                                 List<MoveLog.Record> moves) {
        int moved = 0;
        for (VFile f : group.allFiles()) {
            if (f.parentId != null && f.parentId.equals(targetDir.docId)) {
                continue;
            }
            String targetName = f.name;
            Set<String> existing = namesOf(st, targetDir, dirNames);
            if (existing.contains(targetName)) {
                // 目标里已有同名文件：先判断是不是「同一份内容」（v0.1.58）。
                // 是的话直接把源文件删掉，不要再生成「歌 (1).mp3」——
                // 以前这种情况会一路复制出副本，用户看到的就是「整理之后多出一堆重复文件」。
                if (sameAsTarget(st, f, targetDir, targetName)) {
                    if (st.delete(f)) {
                        log.log("去重：目标已有同名同内容文件，删除源文件：" + f.name, "info");
                        continue;
                    }
                }
                // 内容不同才算真冲突 → 生成唯一后缀，保持音频/歌词基名一致
                targetName = uniqueName(targetName, existing);
                if (targetName.equals(f.name)) {
                    log.log("移动失败：" + f.name + "（目标同名且无法生成唯一名）", "error");
                    continue;
                }
                if (!st.rename(f, targetName)) {
                    log.log("移动失败：" + f.name + "（改名为 " + targetName + " 失败，可能同名或系统不允许）", "error");
                    continue;
                }
            }
            String fromDir = f.parentId == null ? "" : f.parentId;
            String fromName = f.name;
            String why = st.moveWithReason(f, targetDir);
            if (why == null) {
                moved++;
                existing.add(targetName);
                if (moves != null) {
                    moves.add(new MoveLog.Record(batchId, time, fromDir, fromName,
                            targetDir.docId, targetName));
                }
            } else {
                log.log("移动失败：" + f.name + "（" + why + "）", "error");
            }
        }
        return moved;
    }

    /**
     * 目标目录里是否已有「同名且内容相同」的文件。
     *
     * <p>先比大小（便宜），只有大小相同才读双方前 64KB 算哈希。
     * 用于整理时避免把重复文件搬成「歌 (1).mp3」——那正是「整理后多出一堆重复」的来源。
     */
    private static boolean sameAsTarget(Storage st, VFile source, VFile targetDir, String name) {
        try {
            VFile hit = st.findChild(targetDir, name);
            if (hit == null || hit.dir || hit.size != source.size || source.size <= 0) {
                return false;
            }
            String a = DupFiles.hash(st.headBytes(source, DupFiles.HEAD_BYTES));
            String b = DupFiles.hash(st.headBytes(hit, DupFiles.HEAD_BYTES));
            return !a.isEmpty() && a.equals(b);
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * 删掉「明明已经搬走、却还留在原目录」的同名文件。
     *
     * <p>只在确认「目标位置确实有这份文件」时删，避免把源文件误删：
     * 逐个核对 {@code MoveLog.Record} 的 fromDir/fromName 与目标目录里的同名文件。
     *
     * <p>开销：每个「搬出过的目录」只列一次，与文件数无关。
     */
    private static int cleanLeftovers(Storage st, List<MoveLog.Record> moves, Logger log) {
        Map<String, Set<String>> byDir = new HashMap<String, Set<String>>();
        for (MoveLog.Record r : moves) {
            if (r == null || r.fromDir == null || r.fromDir.isEmpty()) {
                continue;
            }
            Set<String> names = byDir.get(r.fromDir);
            if (names == null) {
                names = new HashSet<String>();
                byDir.put(r.fromDir, names);
            }
            names.add(r.fromName);
        }
        int removed = 0;
        for (Map.Entry<String, Set<String>> e : byDir.entrySet()) {
            try {
                VFile dir = new VFile(e.getKey(), null, "",
                        "vnd.android.document/directory", 0L, 0L, true);
                for (VFile c : st.children(dir)) {
                    if (c.dir || !e.getValue().contains(c.name)) {
                        continue;
                    }
                    if (st.delete(c)) {
                        removed++;
                    }
                }
            } catch (Exception ignored) {
                // 列不出来就算了：清理是兜底，不该影响整理结果
            }
        }
        if (removed > 0 && log != null) {
            log.log("注意：有 " + removed + " 个文件搬走后仍留在原目录（系统移动未真正删除源文件），已清理",
                    "warning");
        }
        return removed;
    }

    private static String uniqueName(String name, Set<String> existing) {
        String stem = name;
        String ext = "";
        int dot = name.lastIndexOf('.');
        if (dot > 0) {
            stem = name.substring(0, dot);
            ext = name.substring(dot);
        }
        for (int i = 1; i < 1000; i++) {
            String candidate = stem + "_" + i + ext;
            if (!existing.contains(candidate)) {
                return candidate;
            }
        }
        return name;
    }

    /**
     * 多级目录逐层创建（SAF 只能一层一层建）；空路径返回根目录。
     *
     * <p><b>为什么要带 {@code index} 缓存</b>：{@link Storage#ensureDir} 的实现是
     * 「列一遍父目录再找同名」，而这里是**每组都调一次**。整理 1212 组、根目录下逐渐
     * 出现上千个歌手目录时，等于把根目录反复列了一千多遍 —— 实测每组 0.5 秒左右，
     * 而且越到后面越慢。缓存之后根目录只列一次，新建的目录直接记进缓存。
     *
     * @param index 目录 docId → (子目录名 → VFile)，整轮整理共用一份
     */
    private static VFile ensurePath(Storage st, VFile root, String rel,
                                    Map<String, Map<String, VFile>> index,
                                    Map<String, Set<String>> dirNames) throws java.io.IOException {
        VFile cur = root;
        for (String seg : Layout.segments(rel)) {
            Map<String, VFile> kids = index.get(cur.docId);
            if (kids == null) {
                kids = new HashMap<String, VFile>();
                try {
                    for (VFile c : st.children(cur)) {
                        if (c.dir) {
                            kids.put(c.name, c);
                        }
                    }
                } catch (Exception ignored) {
                    // 列不出来就退化成「每层都问一次」，最多慢一点
                }
                index.put(cur.docId, kids);
            }
            VFile hit = kids.get(seg);
            if (hit == null) {
                hit = st.createDir(cur, seg);
                kids.put(seg, hit);
                // 新目录肯定是空的：直接把名字集合塞进缓存，
                // 免得第一次往里放文件时又列一遍
                dirNames.put(hit.docId, new HashSet<String>());
            }
            cur = hit;
        }
        return cur;
    }

    /**
     * 组的专辑名：取组内第一个能读出非空 album 的音频。
     * 只有「艺人/专辑」这类结构才需要，平铺/纯艺人不读标签（省一次文件头复制）。
     */
    private static String albumOf(Storage st, ContentResolver resolver, TrackGroup group,
                                  Options o) {
        if (o.layout != Layout.ARTIST_ALBUM && o.layout != Layout.ARTIST_ALBUM_JOIN) {
            return "";
        }
        for (VFile f : group.audio) {
            try {
                Tags t = Scanner.readTagsCheap(st, resolver, f);
                String a = t.get("album").trim();
                if (!a.isEmpty()) {
                    return a;
                }
            } catch (Exception ignored) {
                // 单个文件读不出标签就试下一个
            }
        }
        return "";
    }

    public static String simplifyArtistFolder(String name) {
        String text = TextUtil.toSimplified(name == null ? "" : name);
        text = TextUtil.stripTrailingNumericSuffix(text.trim());
        text = text.trim();
        text = text.replaceAll("^[. ]+|[. ]+$", "");
        text = TextUtil.sanitizeFilenameComponent(text, TextUtil.UNKNOWN_ARTIST, 80);
        return text.isEmpty() ? TextUtil.UNKNOWN_ARTIST : text;
    }
}
