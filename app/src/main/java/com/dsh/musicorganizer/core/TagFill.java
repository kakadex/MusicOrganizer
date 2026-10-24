package com.dsh.musicorganizer.core;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 批量标签的「这个字段要不要写」判定（纯逻辑，无 Android 依赖，可离线回归测试）。
 *
 * <p>字段级三态策略（保留 / 覆盖 / 合并）：
 * <ul>
 *   <li>{@link #DISABLED}   不写：这个字段永远不动；</li>
 *   <li>{@link #SUPPLEMENT} 只补空：已有值的字段不动，避免把用户整理好的标签越改越乱（默认）；</li>
 *   <li>{@link #OVERWRITE}  覆盖：候选值与当前值不同就写。</li>
 * </ul>
 *
 * <p>旧的两态 API（{@code boolean overwrite}）仍保留，内部等价于「全覆盖 / 全只补空」，
 * 便于兼容既有调用与测试。
 */
public final class TagFill {

    private TagFill() {
    }

    public static final int DISABLED = 0;
    public static final int SUPPLEMENT = 1;
    public static final int OVERWRITE = 2;

    /** 在线候选能提供的字段（comment 永远不自动写，容易盖掉用户备注）。 */
    public static final String[] CANDIDATE_FIELDS = {
            "title", "artist", "album", "year", "track", "genre",
    };

    /** 字段中文标签（预览/设置里显示）。 */
    public static String label(String key) {
        String l = Tags.LABELS.get(key);
        return l == null ? key : l;
    }

    /** 三态的中文名。 */
    public static String modeName(int mode) {
        switch (mode) {
            case DISABLED:
                return "不写";
            case OVERWRITE:
                return "覆盖";
            default:
                return "只补空";
        }
    }

    /** 默认策略：overwrite ? 全覆盖 : 全只补空。 */
    public static Map<String, Integer> defaultModes(boolean overwrite) {
        Map<String, Integer> m = new LinkedHashMap<String, Integer>();
        for (String f : CANDIDATE_FIELDS) {
            m.put(f, overwrite ? OVERWRITE : SUPPLEMENT);
        }
        return m;
    }

    /** 取某字段策略；缺省按「只补空」。 */
    public static int modeOf(Map<String, Integer> modes, String key) {
        if (modes == null) {
            return SUPPLEMENT;
        }
        Integer m = modes.get(key);
        return m == null ? SUPPLEMENT : m.intValue();
    }

    /**
     * 三态差异：DISABLED 不写、SUPPLEMENT 只补空、OVERWRITE 不同就写。
     * 返回空 Map 表示这首不用动。
     */
    public static Map<String, String> diff(Tags before, Map<String, String> candidate,
                                           Map<String, Integer> modes) {
        Map<String, String> out = new LinkedHashMap<String, String>();
        if (candidate == null) {
            return out;
        }
        for (String key : CANDIDATE_FIELDS) {
            int mode = modeOf(modes, key);
            if (mode == DISABLED) {
                continue;
            }
            String newValue = TextUtil.safeStr(candidate.get(key)).trim();
            if (newValue.isEmpty()) {
                continue;
            }
            String oldValue = before == null ? "" : TextUtil.safeStr(before.get(key)).trim();
            if (oldValue.equals(newValue)) {
                continue;
            }
            if (mode == SUPPLEMENT && !oldValue.isEmpty()) {
                continue;
            }
            out.put(key, newValue);
        }
        return out;
    }

    /** 三态饱和：所有 SUPPLEMENT 字段都已有值、且没有 OVERWRITE 字段 → 无字段可写。 */
    public static boolean isSaturated(Tags before, Map<String, Integer> modes) {
        if (before == null) {
            return false;
        }
        for (String key : CANDIDATE_FIELDS) {
            int mode = modeOf(modes, key);
            if (mode == OVERWRITE) {
                return false;
            }
            if (mode == SUPPLEMENT && TextUtil.safeStr(before.get(key)).trim().isEmpty()) {
                return false;
            }
        }
        return true;
    }

    // ------------------------------------------------------------------
    // 兼容旧两态 API（委托到三态）
    // ------------------------------------------------------------------

    /** 两态差异：overwrite=true 覆盖，false 只补空。 */
    public static Map<String, String> diff(Tags before, Map<String, String> candidate,
                                           boolean overwrite) {
        return diff(before, candidate, defaultModes(overwrite));
    }

    /** 两态饱和判断。 */
    public static boolean isSaturated(Tags before, boolean overwrite) {
        return isSaturated(before, defaultModes(overwrite));
    }

    /** 预览摘要，如「标题、专辑、年份」。 */
    public static String describe(Map<String, String> updates) {
        if (updates == null || updates.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        for (String key : updates.keySet()) {
            if (sb.length() > 0) {
                sb.append('、');
            }
            sb.append(label(key));
        }
        return sb.toString();
    }
}
