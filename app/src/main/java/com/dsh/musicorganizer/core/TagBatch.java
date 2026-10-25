package com.dsh.musicorganizer.core;

import android.content.ContentResolver;
import android.content.Context;

import com.dsh.musicorganizer.net.MbClient;
import com.dsh.musicorganizer.net.Net;
import com.dsh.musicorganizer.net.Sources;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 批量在线获取标签 —— 与歌词一致的「两阶段」：
 *   fetchMatches 只联网查询并算出差异，**不写任何文件**；
 *   用户在预览里勾选确认后，才由 writeMatches 逐条走 TagTransaction 事务写入。
 *
 * 只处理能写标签的格式（MP3 / FLAC），其它格式跳过并在日志里说明。
 *
 * <p><b>并发</b>：第一阶段按 {@link Net#FILE_CONCURRENCY} 路并发处理多首歌，
 * 每首歌内部再由 {@link Sources#aggregate} 并发查多个源 —— 老版本是「一首一首、
 * 一个源一个源」串行，网络差时几乎卡死。写入阶段仍<b>串行</b>：
 * 事务日志与撤销要靠顺序，并发写盘得不偿失。
 */
public final class TagBatch {

    private TagBatch() {
    }

    /** 低于该置信度的候选不展示（八个源都可能返回毫不相关的结果）。 */
    public static final double MIN_CONFIDENCE = 0.30;

    /** 一条待确认的标签匹配结果。 */
    public static class Match {
        public VFile file;
        public Tags before = new Tags();
        public Map<String, String> updates = new HashMap<String, String>();
        public String matchedTitle = "";
        public String matchedArtist = "";
        public String matchedAlbum = "";
        public String source = "";
        public double confidence = 0;
        public boolean selected = true;
        /** 这条是从中间态队列续跑来的（没重新联网，预览里会标注）。 */
        public boolean resumed;

        /** 预览文案：动了哪些字段（只有字段名）。 */
        public String fieldSummary() {
            return TagFill.describe(updates);
        }

        /**
         * 预览列表用：逐字段「旧值 → 新值」，每行一个字段。
         *
         * <p>为什么要在列表里就摊开对比：用户要判断「这条该不该写」，靠的是
         * 「现在是什么、会变成什么」；只给字段名或只给新值，都得靠猜。
         * 旧值为空时写「（空）」，避免留白让人误以为是没读到。
         */
        public String fieldCompare() {
            if (updates == null || updates.isEmpty()) {
                return "";
            }
            StringBuilder sb = new StringBuilder();
            for (String key : Tags.KEYS) {
                String value = updates.get(key);
                if (value == null || value.isEmpty()) {
                    continue;
                }
                String label = Tags.LABELS.containsKey(key) ? Tags.LABELS.get(key) : key;
                String old = before == null ? "" : TextUtil.safeStr(before.get(key));
                sb.append("\n    ").append(label).append("：")
                        .append(old.isEmpty() ? "（空）" : clip(old, 14))
                        .append(" → ").append(clip(value, 20));
            }
            return sb.toString();
        }

        /**
         * 明细用：逐字段「新值（原：旧值）」，一眼看出是补空缺还是改已有值。
         * 旧值为空写「空」，不要留白 —— 用户需要区分「原来有值被我覆盖」和「原来就是空的」。
         */
        public String detail() {
            if (updates == null || updates.isEmpty()) {
                return "（无字段改动）";
            }
            StringBuilder sb = new StringBuilder();
            for (String key : Tags.KEYS) {
                String value = updates.get(key);
                if (value == null || value.isEmpty()) {
                    continue;
                }
                String label = Tags.LABELS.containsKey(key) ? Tags.LABELS.get(key) : key;
                String old = before == null ? "" : TextUtil.safeStr(before.get(key));
                sb.append("\n  ").append(label).append("：").append(clip(value, 60))
                        .append("　（原：").append(old.isEmpty() ? "空" : clip(old, 30)).append("）");
            }
            return sb.length() == 0 ? "（无字段改动）" : sb.toString();
        }

        /** 明细用：这首歌当前的标签，便于对比「现在是什么」和「要变成什么」。 */
        public String beforeSummary() {
            if (before == null) {
                return "（空）";
            }
            StringBuilder sb = new StringBuilder();
            for (String key : Tags.KEYS) {
                String value = TextUtil.safeStr(before.get(key));
                if (value.isEmpty()) {
                    continue;
                }
                if (sb.length() > 0) {
                    sb.append('、');
                }
                sb.append(Tags.LABELS.containsKey(key) ? Tags.LABELS.get(key) : key)
                        .append('=').append(clip(value, 14));
            }
            return sb.length() == 0 ? "（空）" : sb.toString();
        }

        /**
         * 置信度偏低。UI 据此加「低置信」标记 —— 默认仍然勾选（不擅自改变用户既有预期），
         * 但要让用户一眼看见这条是靠不太住的，值不值得写由他决定。
         */
        public boolean lowConfidence() {
            return confidence < 0.50;
        }

        private static String clip(String text, int max) {
            if (text == null) {
                return "";
            }
            String t = text.replace('\r', ' ').replace('\n', ' ').trim();
            return t.length() <= max ? t : t.substring(0, max) + "…";
        }
    }

    /**
     * 第一阶段：批量联网匹配标签，只返回结果，不写文件。
     * 返回顺序与传入的 files 顺序一致（被跳过的文件不占位）。
     */
    public static List<Match> fetchMatches(final Storage st, final ContentResolver resolver,
                                           final MbClient client, List<VFile> files,
                                           final boolean overwriteExisting,
                                           final double filenameWeight, final boolean useCnSources,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log) {
        return fetchMatches(st, resolver, client, files, TagFill.defaultModes(overwriteExisting),
                filenameWeight, useCnSources, null, progress, cancel, log);
    }

    /**
     * 同上，但把每条匹配成功的标签**一产出就放进 {@code sink}** ——
     * 用户中途暂停时可直接预览「已获取的部分」，不必等整批跑完。
     *
     * @param sink 可为 null（不需要暂停预览时）
     */
    public static List<Match> fetchMatches(final Storage st, final ContentResolver resolver,
                                           final MbClient client, List<VFile> files,
                                           final boolean overwriteExisting,
                                           final double filenameWeight, final boolean useCnSources,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log) {
        return fetchMatches(st, resolver, client, files, TagFill.defaultModes(overwriteExisting),
                filenameWeight, useCnSources, sink, progress, cancel, log);
    }

    /**
     * 字段级策略版本：{@code fieldModes} 逐字段控制「不写 / 只补空 / 覆盖」，
     * 见 {@link TagFill#DISABLED} / {@link TagFill#SUPPLEMENT} / {@link TagFill#OVERWRITE}。
     * 其余同两态版本。
     */
    public static List<Match> fetchMatches(final Storage st, final ContentResolver resolver,
                                           final MbClient client, List<VFile> files,
                                           final Map<String, Integer> fieldModes,
                                           final double filenameWeight, final boolean useCnSources,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log) {
        return fetchMatches(st, resolver, client, files, fieldModes, filenameWeight, useCnSources,
                sink, progress, cancel, log, null);
    }

    /**
     * 带「匹配记忆」的版本：{@code memory} 不为 null 时，上批已确认「查不到」或「已写入」的歌
     * 直接跳过，不再联网 —— 这是「重复获取」和「中断后从头来」两个痛点的解药。
     */
    public static List<Match> fetchMatches(final Storage st, final ContentResolver resolver,
                                           final MbClient client, List<VFile> files,
                                           final Map<String, Integer> fieldModes,
                                           final double filenameWeight, final boolean useCnSources,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log, final BatchMemory memory) {
        return fetchMatches(st, resolver, client, files, fieldModes, filenameWeight, useCnSources,
                sink, progress, cancel, log, memory, null);
    }

    /**
     * 再带一个 {@link BatchSkip} 的版本：把「按记忆跳过」的歌收集起来，
     * 界面据此给出「重新查询这 N 首」的入口。
     */
    public static List<Match> fetchMatches(final Storage st, final ContentResolver resolver,
                                           final MbClient client, List<VFile> files,
                                           final Map<String, Integer> fieldModes,
                                           final double filenameWeight, final boolean useCnSources,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log, final BatchMemory memory,
                                           final BatchSkip skip) {
        return fetchMatches(st, resolver, client, files, fieldModes, filenameWeight, useCnSources,
                sink, progress, cancel, log, memory, skip, null);
    }

    /**
     * 同上，额外接一个中间态队列：上次匹配好但没写完的结果，这次直接复用，不再联网。
     *
     * <p>这是「断点续跑」的落点。队列为空时行为与不带队列完全一致。
     */
    public static List<Match> fetchMatches(final Storage st, final ContentResolver resolver,
                                           final MbClient client, List<VFile> files,
                                           final Map<String, Integer> fieldModes,
                                           final double filenameWeight, final boolean useCnSources,
                                           final PartialSink<Match> sink,
                                           final Progress progress, final CancelToken cancel,
                                           final Logger log, final BatchMemory memory,
                                           final BatchSkip skip, final MatchQueue queue) {
        // 去重：重叠授权 / 重复扫描可能让同一个文档出现多次，只处理一次
        final java.util.LinkedHashMap<String, VFile> seen =
                new java.util.LinkedHashMap<String, VFile>();
        for (VFile f : files) {
            String key = (f.docId == null || f.docId.isEmpty()) ? f.name : f.docId;
            if (!seen.containsKey(key)) {
                seen.put(key, f);
            }
        }
        final List<VFile> deduped = new java.util.ArrayList<VFile>(seen.values());
        final int removed = files.size() - deduped.size();
        files = deduped;

        final int total = files.size();
        final AtomicInteger done = new AtomicInteger();
        final AtomicInteger skippedFormat = new AtomicInteger();
        final AtomicInteger saturated = new AtomicInteger();
        final AtomicInteger skippedKnown = new AtomicInteger();
        final AtomicInteger resumed = new AtomicInteger();

        List<Match> raw = Net.mapIndexed(files, Net.fileConcurrency(), cancel,
                new Net.IndexedWork<VFile, Match>() {
                    @Override
                    public Match run(int index, VFile file) {
                        try {
                            Match m = one(st, resolver, client, file, fieldModes,
                                    filenameWeight, useCnSources, cancel, log,
                                    skippedFormat, saturated, memory, skippedKnown, skip,
                                    queue, resumed);
                            if (sink != null && m != null) {
                                sink.add(index, m);
                            }
                            return m;
                        } finally {
                            int d = done.incrementAndGet();
                            if (progress != null) {
                                // 并发下各文件完成顺序不定，只报稳定进度、不报文件名
                                progress.onProgress(d, total,
                                        "匹配标签 " + d + "/" + total);
                            }
                        }
                    }
                });

        List<Match> out = new ArrayList<Match>();
        for (Match m : raw) {
            if (m != null) {
                out.add(m);
            }
        }

        if (log != null) {
            if (removed > 0) {
                log.log("标签匹配：去重 " + removed + " 个重复文件", "info");
            }
            StringBuilder sb = new StringBuilder();
            sb.append("标签匹配完成：待确认 ").append(out.size()).append(" 首");
            if (saturated.get() > 0) {
                sb.append("，标签已完整跳过 ").append(saturated.get());
            }
            if (skippedFormat.get() > 0) {
                sb.append("，不支持写入格式 ").append(skippedFormat.get());
            }
            if (skippedKnown.get() > 0) {
                sb.append("，按记忆跳过 ").append(skippedKnown.get());
            }
            if (resumed.get() > 0) {
                sb.append("，续跑上次结果 ").append(resumed.get());
            }
            log.log(sb.toString(), "info");
        }
        if (memory != null) {
            memory.save();
        }
        if (queue != null) {
            queue.save();
        }
        return out;
    }

    /** 单个文件的匹配逻辑（并发执行，方法内不共享可变状态）。 */
    private static Match one(Storage st, ContentResolver resolver, MbClient client, VFile file,
                             Map<String, Integer> fieldModes, double filenameWeight,
                             boolean useCnSources,
                             CancelToken cancel, Logger log,
                             AtomicInteger skippedFormat, AtomicInteger saturated,
                             BatchMemory memory, AtomicInteger skippedKnown, BatchSkip skip,
                             MatchQueue queue, AtomicInteger resumed) {
        if (!file.audio()) {
            return null;
        }
        String ext = file.ext();
        if (!TagIO.canWrite(ext)) {
            skippedFormat.incrementAndGet();
            return null;
        }
        // 记忆优先：上批已确认「查不到 / 已写入」的直接跳过，省掉一整轮 8 源查询
        final String memKey = memKey(file);
        if (memory != null && memory.shouldSkip(memKey, file.size, file.lastModified)) {
            skippedKnown.incrementAndGet();
            if (skip != null) {
                skip.addMemory(file); // 记下来：界面要给「重新查询这 N 首」的入口
            }
            return null;
        }
        try {
            Tags before = Scanner.readTagsCheap(st, resolver, file);
            if (TagFill.isSaturated(before, fieldModes)) {
                saturated.incrementAndGet();
                return null;
            }
            // 续跑优先：上次已经匹配好、只是没来得及写入的，直接复用，省掉一整轮 8 源查询。
            // 「忽略匹配记忆」开关打开时一并忽略中间态 —— 那是用户明确要求全部重查。
            if (queue != null && !(memory != null && memory.ignoreExisting())) {
                Match rm = fromQueue(queue.take(memKey, file.size, file.lastModified), before, file);
                if (rm != null) {
                    resumed.incrementAndGet();
                    if (log != null) {
                        log.log("标签续跑：沿用上次匹配结果 · " + file.name, "info");
                    }
                    return rm;
                }
            }
            Sources.Query q = new Sources.Query();
            q.filenameCandidates.addAll(NameParser.candidatePairs(file.stem()));
            q.embeddedTags.put("title", before.get("title"));
            q.embeddedTags.put("artist", before.get("artist"));
            q.localDuration = Scanner.durationOf(st, resolver, file);
            q.useCnSources = useCnSources;
            q.filenameWeight = filenameWeight;

            // 进度由文件级统一上报，这里不传 progress（并发写同一条消息会打架）
            List<Sources.Candidate> candidates = Sources.aggregate(client, q, null, cancel);
            if (candidates.isEmpty()) {
                if (memory != null) {
                    memory.record(memKey, file.size, file.lastModified, BatchMemory.NO_HIT);
                }
                if (log != null) {
                    log.log("标签匹配：没有候选 · " + file.name, "warning");
                }
                return null;
            }
            Sources.Candidate best = candidates.get(0);
            if (best.confidence < MIN_CONFIDENCE) {
                if (memory != null) {
                    memory.record(memKey, file.size, file.lastModified, BatchMemory.REJECTED);
                }
                if (log != null) {
                    log.log("标签匹配：候选置信度过低（" + String.format("%.2f", best.confidence)
                            + "）· " + file.name, "warning");
                }
                return null;
            }
            Map<String, String> cand = new HashMap<String, String>();
            cand.put("title", best.title);
            cand.put("artist", best.artist);
            cand.put("album", best.album);
            cand.put("year", best.year);
            cand.put("track", best.track);
            cand.put("genre", best.genre);
            Map<String, String> updates = TagFill.diff(before, cand, fieldModes);
            if (updates.isEmpty()) {
                // 字段策略判定为「无需改动」，下次也不必再查这首歌
                if (memory != null) {
                    memory.record(memKey, file.size, file.lastModified, BatchMemory.DONE);
                }
                return null;
            }
            Match m = new Match();
            m.file = file;
            m.before = before;
            m.updates = updates;
            m.matchedTitle = best.title;
            m.matchedArtist = best.artist;
            m.matchedAlbum = best.album;
            m.source = best.source;
            m.confidence = best.confidence;
            m.selected = true;
            // 中间态落库：这条已经匹配好，即使进程马上被杀，下次也能从这里接着写
            if (queue != null) {
                queue.put(memKey, file.size, file.lastModified, queueFields(m));
            }
            return m;
        } catch (Exception e) {
            if (log != null) {
                log.log("标签匹配失败：" + file.name + "（" + TextUtil.shortError(e) + "）", "error");
            }
            return null;
        }
    }

    /**
     * 第二阶段：把用户确认过的差异逐条事务写入。
     * 同一次批量共用一个 batchId，撤销时整批回滚。
     * 写盘保持串行（事务日志需要顺序，并发写同一目录也会互相拖慢）。
     *
     * @return {written, skipped, failed}
     */
    public static int[] writeMatches(Storage st, ContentResolver resolver, Context ctx,
                                     List<Match> matches, Progress progress,
                                     CancelToken cancel, Logger log) {
        return writeMatches(st, resolver, ctx, matches, progress, cancel, log, null);
    }

    /**
     * 同 {@link #writeMatches(Storage, ContentResolver, Context, List, Progress, CancelToken, Logger)}，
     * 额外把失败原因收进 errorSink（最多留 8 条），供界面直接展示。
     * 只写日志不够 —— 用户看到「失败 110 个」却不知道该改什么。
     */
    public static int[] writeMatches(Storage st, ContentResolver resolver, Context ctx,
                                     List<Match> matches, Progress progress,
                                     CancelToken cancel, Logger log, List<String> errorSink) {
        return writeMatches(st, resolver, ctx, matches, progress, cancel, log, errorSink, null);
    }

    /** 同上，写成功后把该文件记进匹配记忆（下一批直接跳过）。 */
    public static int[] writeMatches(Storage st, ContentResolver resolver, Context ctx,
                                     List<Match> matches, Progress progress,
                                     CancelToken cancel, Logger log, List<String> errorSink,
                                     BatchMemory memory) {
        return writeMatches(st, resolver, ctx, matches, progress, cancel, log, errorSink,
                memory, null);
    }

    /**
     * 同上，并同步中间态队列：写成功 / 跳过 / 失败的都收尾，只剩没轮到的继续待命。
     *
     * <p>这一步是「续跑」能否收敛的关键：如果写完不销账，下次还会把同一批再列出来。
     */
    public static int[] writeMatches(Storage st, ContentResolver resolver, Context ctx,
                                     List<Match> matches, Progress progress,
                                     CancelToken cancel, Logger log, List<String> errorSink,
                                     BatchMemory memory, MatchQueue queue) {
        int written = 0;
        int skipped = 0;
        int failed = 0;
        int done = 0;
        String batchId = "batch-" + System.currentTimeMillis();
        for (Match m : matches) {
            done++;
            if (cancel != null && cancel.isCancelled()) {
                break;
            }
            if (progress != null) {
                progress.onProgress(done, matches.size(),
                        "写入标签 " + done + "/" + matches.size() + "：" + m.file.name);
            }
            if (!m.selected || m.updates.isEmpty()) {
                skipped++;
                if (queue != null) {
                    queue.mark(memKey(m.file), MatchQueue.SKIPPED);
                }
                continue;
            }
            try {
                String err = TagTransaction.apply(st, resolver, ctx, m.file, m.updates,
                        true, batchId, null);
                if (err.isEmpty()) {
                    written++;
                    if (memory != null) {
                        memory.markDone(memKey(m.file), m.file.size, m.file.lastModified);
                    }
                    if (queue != null) {
                        queue.mark(memKey(m.file), MatchQueue.WRITTEN);
                    }
                } else {
                    failed++;
                    if (log != null) {
                        log.log("标签写入失败：" + m.file.name + "（" + err + "）", "error");
                    }
                    note(errorSink, m.file.name, err);
                    if (queue != null) {
                        // 失败就销账：下次重新匹配比反复重试同一条更有意义
                        queue.mark(memKey(m.file), MatchQueue.FAILED);
                    }
                }
            } catch (Exception e) {
                failed++;
                if (log != null) {
                    log.log("标签写入异常：" + m.file.name + "（" + TextUtil.shortError(e) + "）",
                            "error");
                }
                note(errorSink, m.file.name, TextUtil.shortError(e));
                if (queue != null) {
                    queue.mark(memKey(m.file), MatchQueue.FAILED);
                }
            }
        }
        if (memory != null) {
            memory.save();
        }
        if (queue != null) {
            // 收尾：写成功/跳过/失败的都销账，只留下「这一批没轮到的」等下次续跑
            queue.clearFinished();
        }
        return new int[]{written, skipped, failed};
    }

    /** 记忆键：docId 优先，退化为文件名。 */
    /**
     * 匹配记忆的键：优先 docId（唯一），退化为文件名。
     *
     * <p>public 是为了让界面层在「重新查询这 N 首」时按同一套键清记忆 ——
     * 键的算法必须只有一处，两边算不一致就会「清了还是跳过」。
     */
    public static String memKey(VFile f) {
        return (f.docId == null || f.docId.isEmpty()) ? f.name : f.docId;
    }

    // ------------------------------------------------------------------
    // 中间态（断点续跑）
    // ------------------------------------------------------------------

    /** 把一条匹配结果摊平成队列字段：真正的待写字段 + 预览要显示的来源信息。 */
    static Map<String, String> queueFields(Match m) {
        Map<String, String> f = new java.util.LinkedHashMap<String, String>();
        if (m.updates != null) {
            f.putAll(m.updates);
        }
        // 以 @ 开头的键不会和标签字段撞名
        f.put("@t", TextUtil.safeStr(m.matchedTitle));
        f.put("@a", TextUtil.safeStr(m.matchedArtist));
        f.put("@al", TextUtil.safeStr(m.matchedAlbum));
        f.put("@src", TextUtil.safeStr(m.source));
        f.put("@conf", String.valueOf(m.confidence));
        return f;
    }

    /**
     * 从队列里还原一条匹配结果；字段为空返回 null（当作没命中过）。
     *
     * <p>{@code before} 现读：队列只在指纹一致时才给，所以读到的就是匹配时那份标签。
     */
    static Match fromQueue(MatchQueue.Item it, Tags before, VFile file) {
        if (it == null) {
            return null;
        }
        Map<String, String> updates = new HashMap<String, String>();
        for (String k : Tags.KEYS) {
            String v = it.fields.get(k);
            if (v != null && !v.isEmpty()) {
                updates.put(k, v);
            }
        }
        if (updates.isEmpty()) {
            return null;
        }
        Match m = new Match();
        m.file = file;
        m.before = before;
        m.updates = updates;
        m.matchedTitle = it.field("@t", "");
        m.matchedArtist = it.field("@a", "");
        m.matchedAlbum = it.field("@al", "");
        m.source = it.field("@src", "");
        m.confidence = parseDouble(it.field("@conf", "0"));
        m.selected = true;
        m.resumed = true;
        return m;
    }

    private static double parseDouble(String s) {
        try {
            return Double.parseDouble(s.trim());
        } catch (Exception e) {
            return 0;
        }
    }

    private static void note(List<String> sink, String name, String reason) {
        if (sink != null && sink.size() < 8) {
            sink.add(name + "：" + reason);
        }
    }
}
