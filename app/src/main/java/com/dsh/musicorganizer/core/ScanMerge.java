package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 增量扫描：把上一次的标签缓存「接力」到这一次的扫描结果上（纯逻辑，桌面 JVM 可测）。
 *
 * <p><b>为什么需要它</b>：重扫目录时 {@link Scanner#walkMusic} 会重新构造一批
 * {@link VFile}，缓存字段全是空的；如果直接拿这批新对象去建索引，整库标签又要重读一遍 ——
 * 这就是「补完一首歌也要整个目录重扫」的根源。
 *
 * <p><b>判定规则是增量同步</b>：同一个 {@code docId} 且
 * {@code size} 与 {@code lastModified} 都没变，就认为内容没被改过，直接沿用上次读到的标签；
 * 只要有一项变了，就当作新文件，交给调用方重读。
 *
 * <p>只比较音频文件：目录与歌词文件不参与索引，元数据接力对它们没有意义。
 */
public final class ScanMerge {

    private ScanMerge() {
    }

    /** 合并结果。 */
    public static final class Result {
        /** 本次扫描出的文件（音频对象的缓存字段已被就地填好）。 */
        public final List<VFile> files;
        /** 沿用了上次标签的音频数。 */
        public final int reused;
        /** 需要重读标签的音频数（新增或被改动）。 */
        public final int fresh;
        /** 上次有、这次没有的音频数。 */
        public final int removed;

        Result(List<VFile> files, int reused, int fresh, int removed) {
            this.files = files;
            this.reused = reused;
            this.fresh = fresh;
            this.removed = removed;
        }

        /** 日志用的一句话。 */
        public String summary() {
            StringBuilder sb = new StringBuilder();
            sb.append("标签复用 ").append(reused).append(" 首");
            if (fresh > 0) {
                sb.append("，需重读 ").append(fresh).append(" 首");
            }
            if (removed > 0) {
                sb.append("，已移除 ").append(removed).append(" 首");
            }
            return sb.toString();
        }
    }

    /**
     * 合并。
     *
     * @param previous 上一次的扫描结果（可为 null / 空）
     * @param current  本次扫描结果；其中音频对象的缓存字段会被就地写入
     */
    public static Result merge(List<VFile> previous, List<VFile> current) {
        // 按 docId 去重（v0.1.57）：上游遍历已经去过一次重，这里再兜一层 ——
        // 同一个文件在列表里出现两条，用户看到的就是「重复的曲目」。
        List<VFile> out = new ArrayList<VFile>();
        if (current != null) {
            Set<String> ids = new HashSet<String>();
            for (VFile f : current) {
                if (f != null && ids.add(f.docId)) {
                    out.add(f);
                }
            }
        }
        Map<String, VFile> before = new HashMap<String, VFile>();
        if (previous != null) {
            for (VFile f : previous) {
                if (f == null || f.dir || !f.audio()) {
                    continue;
                }
                if (!before.containsKey(f.docId)) {
                    before.put(f.docId, f);
                }
            }
        }

        Set<String> seen = new HashSet<String>();
        int reused = 0;
        int fresh = 0;
        for (VFile f : out) {
            if (f == null || f.dir || !f.audio()) {
                continue;
            }
            seen.add(f.docId);
            VFile old = before.get(f.docId);
            if (old != null && sameFile(old, f) && old.metaCached()) {
                // 内容没变：把上次读到的标签直接挂到新对象上，免去一次复制 + 解析
                f.cacheMeta(old.cachedTags, old.cachedHasCover, old.cachedHasLyrics);
                reused++;
            } else {
                f.clearMeta();
                fresh++;
            }
        }

        int removed = 0;
        for (String docId : before.keySet()) {
            if (!seen.contains(docId)) {
                removed++;
            }
        }
        return new Result(out, reused, fresh, removed);
    }

    /**
     * 「还是同一个文件吗」：docId 相同之外，还要 size 与 lastModified 都没变。
     *
     * <p>写标签会同时改 size 和 lastModified，所以正常改过的文件一定判为「变了」；
     * 只有外部工具「等长替换」这种极端情况可能漏判，此时后果是列表显示旧标签，
     * 点开编辑器重读一次即可 —— 比每次全库重读的代价小得多。
     */
    private static boolean sameFile(VFile a, VFile b) {
        return a.size == b.size && a.lastModified == b.lastModified;
    }
}
