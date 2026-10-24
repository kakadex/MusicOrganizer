package com.dsh.musicorganizer.core;

import java.util.HashMap;
import java.util.Map;

/**
 * 统一标签结构：title / artist / album / year / track / genre / comment。
 * 对应 Python 版 _TAG_FIELDS。
 */
public final class Tags {

    public static final String[] KEYS = {
            "title", "artist", "album", "year", "track", "genre", "comment",
    };

    /**
     * 歌词（MP3 的 USLT 帧 / FLAC 的 LYRICS 字段）。
     * 刻意不放进 KEYS：歌词可能几 KB，若进 KEYS 会被编辑器当成普通输入框、
     * 也会被 journal 逐条快照，既撑大界面也撑大撤销日志。
     */
    public static final String LYRICS = "lyrics";

    public static final Map<String, String> LABELS = new HashMap<String, String>();

    static {
        LABELS.put("title", "标题");
        LABELS.put("artist", "艺术家");
        LABELS.put("album", "专辑");
        LABELS.put("year", "年份");
        LABELS.put("track", "音轨");
        LABELS.put("genre", "流派");
        LABELS.put("comment", "注释");
        LABELS.put(LYRICS, "歌词");
    }

    private final Map<String, String> values = new HashMap<String, String>();

    public Tags() {
        for (String k : KEYS) {
            values.put(k, "");
        }
    }

    public String get(String key) {
        String v = values.get(key);
        return v == null ? "" : v;
    }

    public void put(String key, String value) {
        if (key == null) {
            return;
        }
        values.put(key, value == null ? "" : value.trim());
    }

    public boolean anyValue() {
        for (String k : KEYS) {
            if (!values.get(k).isEmpty()) {
                return true;
            }
        }
        return false;
    }

    public Map<String, String> toMap() {
        return new HashMap<String, String>(values);
    }

    public Tags copy() {
        Tags t = new Tags();
        for (Map.Entry<String, String> e : values.entrySet()) {
            t.values.put(e.getKey(), e.getValue());
        }
        return t;
    }

    @Override
    public String toString() {
        return values.toString();
    }
}
