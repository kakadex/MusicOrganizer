package com.dsh.musicorganizer.core;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 批量编辑：给多首歌一次性设同一批字段。
 *
 * <p>与「在线匹配」的区别：匹配是**逐首取不同值**，批量编辑是**人为指定同一值**
 * （整张专辑统一专辑名、统一流派、从 1 开始重排音轨号）。纯逻辑放在这里，
 * 方便在桌面 JVM 里跑回归 —— 写盘本身仍然走 {@link TagTransaction}。
 */
public final class BatchEdit {

    private BatchEdit() {
    }

    /** 可批量编辑的字段（顺序即界面上的顺序）。 */
    public static final String[] FIELDS = {
            "title", "artist", "album", "genre", "year", "comment"
    };

    /** 一次批量编辑的规格：只包含「用户勾选并填了值」的字段。 */
    public static final class Spec {
        /** 字段 → 新值（不含 track，音轨单独处理）。 */
        public final Map<String, String> values = new LinkedHashMap<String, String>();
        /** 是否把音轨号按文件顺序重排。 */
        public boolean renumberTrack;
        /** 音轨起始编号（一般从 1 开始，多碟专辑第二碟可能从 11 开始）。 */
        public int trackStart = 1;

        public boolean isEmpty() {
            return values.isEmpty() && !renumberTrack;
        }

        /** 一句话描述，用于确认框与日志。 */
        public String summary() {
            if (isEmpty()) {
                return "没有要修改的字段";
            }
            StringBuilder sb = new StringBuilder();
            for (Map.Entry<String, String> e : values.entrySet()) {
                if (sb.length() > 0) {
                    sb.append("，");
                }
                String label = Tags.LABELS.get(e.getKey());
                sb.append(label == null ? e.getKey() : label)
                        .append(" → ")
                        .append(e.getValue().isEmpty() ? "（清空）" : e.getValue());
            }
            if (renumberTrack) {
                if (sb.length() > 0) {
                    sb.append("，");
                }
                sb.append("音轨号按顺序重排（从 ").append(trackStart).append(" 开始）");
            }
            return sb.toString();
        }
    }

    /**
     * 第 {@code index} 个文件要写入的字段。
     *
     * @param index 0 起的文件序号（决定音轨号）
     */
    public static Map<String, String> updatesFor(Spec spec, int index) {
        Map<String, String> out = new LinkedHashMap<String, String>();
        if (spec == null) {
            return out;
        }
        for (Map.Entry<String, String> e : spec.values.entrySet()) {
            // 空字符串在写入层表示「清除该字段」，这里原样传递
            out.put(e.getKey(), e.getValue() == null ? "" : e.getValue());
        }
        if (spec.renumberTrack) {
            out.put("track", String.valueOf(spec.trackStart + index));
        }
        return out;
    }

    /** 能被批量编辑的文件数（只算可写标签的格式，其它跳过）。 */
    public static int editableCount(java.util.List<VFile> files) {
        int n = 0;
        for (VFile f : files) {
            if (!f.dir && TagIO.canWrite(f.ext())) {
                n++;
            }
        }
        return n;
    }
}
