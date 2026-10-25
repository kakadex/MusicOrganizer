package com.dsh.musicorganizer.net;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 在线源注册表（v0.1.80）。
 *
 * <p>一处登记「有哪些源、各自能做什么、怎么搜」，聚合流程只跟这里打交道。
 * 新增一家：写一个 {@link OnlineSource} 实现 → 在这里 {@code register(...)} 一行，
 * 不用再改 if-else 链。
 *
 * <p>注意：<b>启用/停用</b>仍然由 {@code Endpoints} 管（用户可在设置里单独关掉某一家），
 * 顺序由 {@code SourceRank} 管（中文歌国内优先）。这里只负责「有哪些」。
 */
public final class SourceRegistry {

    private static final Map<String, OnlineSource> BY_KEY =
            new LinkedHashMap<String, OnlineSource>();

    static {
        // ---- 海外源
        register(new Base("musicbrainz", "MusicBrainz", true, false, true) {
            @Override
            public List<Sources.Candidate> search(Sources.Query q, MbClient client)
                    throws Exception {
                return Sources.musicBrainz(client, q);
            }
        });
        register(new Base("deezer", "Deezer", true, false, true) {
            @Override
            public List<Sources.Candidate> search(Sources.Query q, MbClient client) {
                return Sources.deezer(q);
            }
        });
        register(new Base("itunes", "iTunes", true, false, true) {
            @Override
            public List<Sources.Candidate> search(Sources.Query q, MbClient client) {
                return Sources.iTunes(q);
            }
        });
        // ---- 国内源（这五家同时能出歌词与封面）
        register(new Base("netease", "网易云", true, true, true) {
            @Override
            public List<Sources.Candidate> search(Sources.Query q, MbClient client) {
                return Sources.netease(q);
            }
        });
        register(new Base("qqmusic", "QQ 音乐", true, true, true) {
            @Override
            public List<Sources.Candidate> search(Sources.Query q, MbClient client) {
                return Sources.qqMusic(q);
            }
        });
        register(new Base("kugou", "酷狗", true, true, true) {
            @Override
            public List<Sources.Candidate> search(Sources.Query q, MbClient client) {
                return Sources.kugou(q);
            }
        });
        register(new Base("kuwo", "酷我", true, true, true) {
            @Override
            public List<Sources.Candidate> search(Sources.Query q, MbClient client) {
                return Sources.kuwo(q);
            }
        });
        register(new Base("migu", "咪咕", true, true, true) {
            @Override
            public List<Sources.Candidate> search(Sources.Query q, MbClient client) {
                return Sources.migu(q);
            }
        });
    }

    private SourceRegistry() {
    }

    private static void register(OnlineSource s) {
        BY_KEY.put(s.key(), s);
    }

    /** 按 key 取源；没有返回 null。 */
    public static OnlineSource get(String key) {
        return key == null ? null : BY_KEY.get(key);
    }

    /** 已登记的全部 key（顺序 = 登记顺序）。 */
    public static List<String> keys() {
        return new ArrayList<String>(BY_KEY.keySet());
    }

    /** 全部源（只读视图），供设置页展示「哪些源支持歌词/封面」。 */
    public static List<OnlineSource> all() {
        return new ArrayList<OnlineSource>(BY_KEY.values());
    }

    /** 能不能出歌词（key 已知才有意义）。 */
    public static boolean supportsLyrics(String key) {
        OnlineSource s = get(key);
        return s != null && s.supportsLyrics();
    }

    /** 能不能出封面。 */
    public static boolean supportsCover(String key) {
        OnlineSource s = get(key);
        return s != null && s.supportsCover();
    }

    /** 省事的基类：只有 key/能力位是固定的，{@code search} 由子类实现。 */
    private abstract static class Base implements OnlineSource {
        private final String key;
        private final String label;
        private final boolean tags;
        private final boolean lyrics;
        private final boolean cover;

        Base(String key, String label, boolean tags, boolean lyrics, boolean cover) {
            this.key = key;
            this.label = label;
            this.tags = tags;
            this.lyrics = lyrics;
            this.cover = cover;
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String label() {
            return label;
        }

        @Override
        public boolean supportsTags() {
            return tags;
        }

        @Override
        public boolean supportsLyrics() {
            return lyrics;
        }

        @Override
        public boolean supportsCover() {
            return cover;
        }
    }
}
