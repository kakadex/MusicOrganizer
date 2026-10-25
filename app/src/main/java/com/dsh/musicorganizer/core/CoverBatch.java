package com.dsh.musicorganizer.core;

import android.content.ContentResolver;

import com.dsh.musicorganizer.net.Http;
import com.dsh.musicorganizer.net.Net;
import com.dsh.musicorganizer.net.Sources;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 批量补专辑封面。
 *
 * <p>为什么要单独一条链路：标签匹配只补文本字段，封面是二进制块（MP3 的 APIC /
 * FLAC 的 PICTURE / MP4 的 covr），既不能塞进「旧值 → 新值」的字段对比，也不能
 * 混在标签事务里一起回滚。但**数据来源完全复用标签源** —— Deezer / iTunes / 网易 / QQ
 * 的搜索结果里本来就带专辑图地址（{@link Sources.Candidate#coverUrl}），
 * 所以不需要另写一套搜索，连置信度判定都是同一套。
 *
 * <p>流程与批量标签一致：先匹配（只读）→ 预览勾选 → 事务写入（下载 + 校验 + 备份 + 回读）。
 * 已有封面的文件默认跳过（除非勾「覆盖已有封面」）。
 */
public final class CoverBatch {

    private CoverBatch() {
    }

    /** 读文件头这么大就够判断「有没有封面」；不够再回退整文件复制（M4A 的 moov 常在尾部）。 */
    private static final int HEAD_BYTES = 2 * 1024 * 1024;
    private static final int DOWNLOAD_TIMEOUT_MS = 8000;

    /** 一条待确认的封面匹配。 */
    public static class Match {
        public VFile file;
        public String album = "";
        public String artist = "";
        /** 候选来自哪个源（deezer / itunes / netease / qqmusic） */
        public String source = "";
        public String url = "";
        public double confidence = 0;
        public boolean selected = true;
        public String note = "";
    }

    /** 批量匹配统计（界面据此解释「为什么一张都没找到」）。 */
    public static class Result {
        public final List<Match> matches = new ArrayList<Match>();
        public int scanned = 0;
        public int audio = 0;
        /** 文件里已经有封面（未勾覆盖） */
        public int hasCover = 0;
        /** 候选里都没有封面地址 */
        public int noCandidate = 0;
        /** 不支持写封面的格式 */
        public int skippedFormat = 0;
        /** 按记忆跳过 */
        public int skippedKnown = 0;
        public int failed = 0;
        public String errorNote = "";
        public boolean stopped = false;

        public boolean isEmpty() {
            return matches.isEmpty();
        }

        public String explain() {
            if (audio == 0) {
                return scanned == 0 ? "没有扫描到任何文件。" : "没有可处理的音频文件。";
            }
            StringBuilder sb = new StringBuilder();
            sb.append("扫描 ").append(audio).append(" 首音频，没有一首拿到封面：\n");
            if (hasCover > 0) {
                sb.append("\n· 已有封面跳过：").append(hasCover)
                        .append(" 首（勾选「覆盖已有封面」可重试）");
            }
            if (noCandidate > 0) {
                sb.append("\n· 候选里没有封面地址：").append(noCandidate).append(" 首");
            }
            if (skippedFormat > 0) {
                sb.append("\n· 格式不支持写封面：").append(skippedFormat).append(" 首");
            }
            if (skippedKnown > 0) {
                sb.append("\n· 按记忆跳过：").append(skippedKnown).append(" 首");
            }
            if (failed > 0) {
                sb.append("\n· 处理出错：").append(failed).append(" 首");
                if (!errorNote.isEmpty()) {
                    sb.append("（").append(errorNote).append("）");
                }
            }
            return sb.toString();
        }
    }

    /** 单文件结果（并发执行，各自独立）。 */
    private static final class One {
        Match match;
        boolean audio;
        boolean hasCover;
        boolean noCandidate;
        boolean skippedFormat;
        boolean skippedKnown;
        boolean failed;
        String error = "";
    }

    /**
     * 第一阶段：为每首歌找一张封面（**不下载、不写盘**），只返回候选。
     *
     * @param overwriteCover true 时连「文件里已有封面」的也重新找
     */
    public static Result fetchMatches(final Storage st, final ContentResolver resolver,
                                      final com.dsh.musicorganizer.net.MbClient client,
                                      List<VFile> files, final double filenameWeight,
                                      final boolean useCnSources, final boolean overwriteCover,
                                      final Progress progress, final CancelToken cancel,
                                      final Logger log, final BatchMemory memory) {
        return fetchMatches(st, resolver, client, files, filenameWeight, useCnSources,
                overwriteCover, progress, cancel, log, memory, null);
    }

    /**
     * 再带一个 {@link BatchSkip} 的版本：把「按记忆跳过」的歌收集起来，
     * 界面据此给出「重新查询这 N 首」的入口。
     */
    public static Result fetchMatches(final Storage st, final ContentResolver resolver,
                                      final com.dsh.musicorganizer.net.MbClient client,
                                      List<VFile> files, final double filenameWeight,
                                      final boolean useCnSources, final boolean overwriteCover,
                                      final Progress progress, final CancelToken cancel,
                                      final Logger log, final BatchMemory memory,
                                      final BatchSkip skip) {
        final Result res = new Result();
        // 去重（重叠授权 / 重复扫描会让同一文件出现两次）
        final LinkedHashMap<String, VFile> seen = new LinkedHashMap<String, VFile>();
        for (VFile f : files) {
            String key = TagBatch.memKey(f);
            if (!seen.containsKey(key)) {
                seen.put(key, f);
            }
        }
        files = new ArrayList<VFile>(seen.values());
        res.scanned = files.size();
        final int total = files.size();
        final AtomicInteger done = new AtomicInteger();

        List<One> parts = Net.mapIndexed(files, Net.fileConcurrency(), cancel,
                new Net.IndexedWork<VFile, One>() {
                    @Override
                    public One run(int index, VFile file) {
                        try {
                            return one(st, resolver, client, file, filenameWeight,
                                    useCnSources, overwriteCover, cancel, log, memory, skip);
                        } finally {
                            int d = done.incrementAndGet();
                            if (progress != null) {
                                progress.onProgress(d, total, "匹配封面 " + d + "/" + total);
                            }
                        }
                    }
                });

        for (One o : parts) {
            if (o == null) {
                continue;
            }
            if (o.audio) {
                res.audio++;
            }
            if (o.match != null) {
                res.matches.add(o.match);
            }
            if (o.hasCover) {
                res.hasCover++;
            }
            if (o.noCandidate) {
                res.noCandidate++;
            }
            if (o.skippedFormat) {
                res.skippedFormat++;
            }
            if (o.skippedKnown) {
                res.skippedKnown++;
            }
            if (o.failed) {
                res.failed++;
            }
            if (res.errorNote.isEmpty() && !o.error.isEmpty()) {
                res.errorNote = o.error;
            }
        }
        if (cancel != null && cancel.isCancelledNow()) {
            res.stopped = true;
        }
        if (memory != null) {
            memory.save();
        }
        if (log != null) {
            log.log("封面匹配：可用 " + res.matches.size() + " 首（已有封面 " + res.hasCover
                    + "，无候选 " + res.noCandidate + "）", "info");
        }
        return res;
    }

    private static One one(Storage st, ContentResolver resolver,
                           com.dsh.musicorganizer.net.MbClient client, VFile file,
                           double filenameWeight, boolean useCnSources, boolean overwriteCover,
                           CancelToken cancel, Logger log, BatchMemory memory, BatchSkip skip) {
        One o = new One();
        if (!file.audio()) {
            return o;
        }
        if (!TagIO.canWrite(file.ext())) {
            o.skippedFormat = true;
            return o;
        }
        o.audio = true;
        final String memKey = TagBatch.memKey(file);
        if (memory != null && memory.shouldSkip(memKey, file.size, file.lastModified)) {
            o.skippedKnown = true;
            if (skip != null) {
                skip.addMemory(file); // 记下来：界面要给「重新查询这 N 首」的入口
            }
            return o;
        }
        try {
            if (!overwriteCover && hasCover(st, file)) {
                o.hasCover = true;
                if (memory != null) {
                    memory.record(memKey, file.size, file.lastModified, BatchMemory.DONE);
                }
                return o;
            }
            Tags tags = Scanner.readTagsCheap(st, resolver, file);
            Sources.Query q = new Sources.Query();
            q.filenameCandidates.addAll(NameParser.candidatePairs(file.stem()));
            q.embeddedTags.put("title", tags.get("title"));
            q.embeddedTags.put("artist", tags.get("artist"));
            q.localDuration = Scanner.durationOf(st, resolver, file);
            q.useCnSources = useCnSources;
            q.filenameWeight = filenameWeight;

            List<Sources.Candidate> candidates = Sources.aggregate(client, q, null, cancel);
            Sources.Candidate best = null;
            for (Sources.Candidate c : candidates) {
                if (c.coverUrl != null && !c.coverUrl.trim().isEmpty()) {
                    best = c;
                    break; // aggregate 已按置信度排序，第一个带封面的就是最好的
                }
            }
            if (best == null) {
                o.noCandidate = true;
                if (memory != null) {
                    memory.record(memKey, file.size, file.lastModified, BatchMemory.NO_HIT);
                }
                return o;
            }
            Match m = new Match();
            m.file = file;
            m.album = best.album;
            m.artist = best.artist;
            m.source = best.source;
            m.url = best.coverUrl.trim();
            m.confidence = best.confidence;
            o.match = m;
        } catch (Exception e) {
            o.failed = true;
            o.error = file.name + "：" + TextUtil.shortError(e);
        }
        return o;
    }

    /** 文件里是否已有内嵌封面（头部不够时回退整文件复制）。 */
    private static boolean hasCover(Storage st, VFile file) {
        File tmp = null;
        try {
            tmp = File.createTempFile("mo_cover_", TagIO.extOf(file.name));
            st.copyHeadToLocal(file, tmp, HEAD_BYTES);
            if (!TagIO.tagFitsCopy(tmp, file.ext())) {
                st.copyToLocal(file, tmp);
            }
            return TagIO.hasCoverLocal(tmp);
        } catch (Exception e) {
            return false;
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
    }

    /**
     * 第二阶段：下载并事务写入。
     *
     * @return {written, skipped, failed}
     */
    public static int[] writeMatches(Storage st, ContentResolver resolver,
                                     android.content.Context ctx, List<Match> matches,
                                     Progress progress, CancelToken cancel, Logger log,
                                     BatchMemory memory) {
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
                progress.onProgress(done, matches.size(), "写入封面：" + m.file.name);
            }
            if (!m.selected) {
                skipped++;
                continue;
            }
            try {
                byte[] image = Http.getBytes(m.url, null, headersFor(m.url),
                        DOWNLOAD_TIMEOUT_MS, CoverArt.MAX_BYTES);
                if (image == null) {
                    failed++;
                    if (log != null) {
                        log.log("封面下载失败：" + m.file.name + "（" + Http.lastError() + "）",
                                "error");
                    }
                    continue;
                }
                if (CoverArt.mimeOf(image).isEmpty()) {
                    failed++;
                    if (log != null) {
                        log.log("封面不是 JPEG/PNG：" + m.file.name, "error");
                    }
                    continue;
                }
                String err = TagTransaction.applyCover(st, resolver, ctx, m.file, image, null);
                if (err.isEmpty()) {
                    written++;
                    if (memory != null) {
                        memory.markDone(TagBatch.memKey(m.file), m.file.size, m.file.lastModified);
                    }
                    if (log != null) {
                        log.log("封面写入成功：" + m.file.name + "（" + CoverArt.describe(image)
                                + "，来自 " + sourceLabel(m.source) + "）", "success");
                    }
                } else {
                    failed++;
                    if (log != null) {
                        log.log("封面写入失败：" + m.file.name + "（" + err + "）", "error");
                    }
                }
            } catch (Exception e) {
                failed++;
                if (log != null) {
                    log.log("封面处理失败：" + m.file.name + "（" + TextUtil.shortError(e) + "）",
                            "error");
                }
            }
        }
        if (memory != null) {
            memory.save();
        }
        return new int[]{written, skipped, failed};
    }

    /** 部分图床按 Referer 判断来源，缺了会 403。 */
    private static Map<String, String> headersFor(String url) {
        // 规则集中在 net/Sources.coverHeaders：候选卡片预览也用同一份，避免两处走偏
        return com.dsh.musicorganizer.net.Sources.coverHeaders(url);
    }

    public static String sourceLabel(String source) {
        if ("deezer".equals(source)) {
            return "Deezer";
        }
        if ("itunes".equals(source)) {
            return "iTunes";
        }
        if ("netease".equals(source)) {
            return "网易云";
        }
        if ("qqmusic".equals(source)) {
            return "QQ 音乐";
        }
        return source == null || source.isEmpty() ? "未知" : source;
    }
}
