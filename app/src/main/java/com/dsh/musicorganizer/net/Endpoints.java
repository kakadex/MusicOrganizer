package com.dsh.musicorganizer.net;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 接口地址注册表 —— 所有联网接口的地址都在这里登记，**不在业务代码里写死**。
 *
 * <p>为什么要有这个：国内这几家音乐站的匿名接口换得很勤（路径改名、域名切 CDN、
 * 老地址直接返 500/405）。地址写死在代码里，一旦某家变了，用户只能等下个版本；
 * 放在这里之后，用户可以在「数据源设置」里自行改地址、或者干脆关掉某个源。
 *
 * <p>本类刻意<b>不依赖 Android</b>（也没有 org.json），这样能在纯 JVM 里跑回归测试。
 * 真正的读写由 UI 层（{@code ui.Repo}）实现 {@link Config} 后注入。
 */
public final class Endpoints {

    private Endpoints() {
    }

    /** 一个数据源可以有一个或多个端点（例如「搜索」+「取详情」）。 */
    public static final class Source {
        /** 源标识，也是启用开关的键，如 netease */
        public final String key;
        /** 界面上显示的名字 */
        public final String label;
        /** 分组：标签 / 歌词 */
        public final String group;
        /** 各端点的短名，与 {@link #defaults} 一一对应 */
        public final String[] names;
        /** 各端点的默认地址 */
        public final String[] defaults;

        Source(String key, String label, String group, String[] names, String[] defaults) {
            this.key = key;
            this.label = label;
            this.group = group;
            this.names = names;
            this.defaults = defaults;
        }

        public int count() {
            return defaults.length;
        }

        /** 端点的完整键，如 {@code netease.0}。 */
        public String endpointKey(int index) {
            return key + "." + index;
        }

        public String name(int index) {
            return index >= 0 && index < names.length ? names[index] : "";
        }

        public String defaultUrl(int index) {
            return index >= 0 && index < defaults.length ? defaults[index] : "";
        }
    }

    /** 读写用户设置。由 UI 层实现（SharedPreferences），未注入时全部用默认值。 */
    public interface Config {
        /** 用户改过的地址；返回 null 或空串表示没改过。 */
        String override(String endpointKey);

        /** 该源是否启用；默认 true。 */
        boolean enabled(String sourceKey);

        /** 记下用户改的地址；传 null 表示恢复默认。 */
        void setOverride(String endpointKey, String url);

        /** 设置源启用状态。 */
        void setEnabled(String sourceKey, boolean enabled);
    }

    private static volatile Config config;

    public static void install(Config c) {
        config = c;
    }

    /** 恢复到「没装任何配置」的状态（测试用）。 */
    public static void uninstall() {
        config = null;
    }

    public static Config configOrNull() {
        return config;
    }

    // ------------------------------------------------------------------
    // 注册表：新增数据源只要在这里加一行
    // ------------------------------------------------------------------

    public static final Source[] SOURCES = {
            new Source("netease", "网易云音乐", "标签",
                    new String[]{"搜索"},
                    new String[]{"https://music.163.com/api/search/get"}),
            new Source("qqmusic", "QQ 音乐", "标签",
                    new String[]{"搜索"},
                    new String[]{"https://u.y.qq.com/cgi-bin/musicu.fcg"}),
            new Source("kugou", "酷狗音乐", "标签",
                    new String[]{"搜索"},
                    new String[]{"https://mobiles.kugou.com/api/v3/search/song"}),
            new Source("kuwo", "酷我音乐", "标签",
                    new String[]{"搜索"},
                    new String[]{"https://search.kuwo.cn/r.s"}),
            new Source("migu", "咪咕音乐", "标签",
                    new String[]{"搜索"},
                    new String[]{"https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do"}),
            new Source("musicbrainz", "MusicBrainz", "标签",
                    new String[]{"搜索"},
                    new String[]{"https://musicbrainz.org/ws/2/recording/"}),
            new Source("deezer", "Deezer", "标签",
                    new String[]{"搜索"},
                    new String[]{"https://api.deezer.com/search"}),
            new Source("itunes", "iTunes", "标签",
                    new String[]{"搜索"},
                    new String[]{"https://itunes.apple.com/search"}),

            new Source("lrclib", "LRCLIB", "歌词",
                    new String[]{"精确查询", "模糊搜索"},
                    new String[]{"https://lrclib.net/api/get",
                            "https://lrclib.net/api/search"}),
            new Source("lyric_netease", "网易云（歌词）", "歌词",
                    new String[]{"搜索", "取歌词"},
                    new String[]{"https://music.163.com/api/search/get",
                            "https://music.163.com/api/song/lyric"}),
            new Source("lyric_qq", "QQ 音乐（歌词）", "歌词",
                    new String[]{"搜索", "取歌词"},
                    new String[]{"https://u.y.qq.com/cgi-bin/musicu.fcg",
                            "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"}),
            new Source("lyric_ovh", "lyrics.ovh", "歌词",
                    new String[]{"按艺人/歌名取词"},
                    new String[]{"https://api.lyrics.ovh/v1"}),
            // 酷狗（v0.1.41）：搜索走 krcs，取词走 lyrics。
            // v0.1.44 改回 https —— 原来用 http 是错的：Android 9+ 默认禁止明文流量
            // （manifest 里没有 cleartextTrafficPermitted），这两个请求在真机上会直接失败。
            // 实测 https 两个域名都返 200。万一某网络下 https 握手失败，用户可改回 http，
            // 届时走 res/xml/network_security_config.xml 里给这两个域名单独开的白名单。
            new Source("lyric_kugou", "酷狗（歌词）", "歌词",
                    new String[]{"搜索", "取歌词"},
                    new String[]{"https://krcs.kugou.com/search",
                            "https://lyrics.kugou.com/download"}),

            // 更新检查 · 国内优先走 Gitee 的 raw 清单（普通静态文件，不要 token、不限速），
            // GitHub 作为兜底。两边都是同一份 dist/latest.txt，格式见 AppUpdate.parseManifest。
            new Source("gitee", "Gitee 更新（国内优先）", "更新",
                    new String[]{"版本清单", "发布页", "仓库主页", "备用接口"},
                    new String[]{"https://gitee.com/kakadex/MusicOrganizer/raw/main/dist/latest.txt",
                            "https://gitee.com/kakadex/MusicOrganizer/releases",
                            "https://gitee.com/kakadex/MusicOrganizer",
                            "https://gitee.com/api/v5/repos/kakadex/MusicOrganizer/releases/latest"}),

            // 更新检查（兜底）：GitHub 在境内偶尔连不上，所以地址也做成可改的
            // （换成镜像/加速地址，或干脆在这里停用它）。
            new Source("update", "GitHub 更新（兜底）", "更新",
                    new String[]{"最新版本接口", "发布页", "仓库主页", "版本清单"},
                    new String[]{"https://api.github.com/repos/kakadex/MusicOrganizer/releases/latest",
                            "https://github.com/kakadex/MusicOrganizer/releases/latest",
                            "https://github.com/kakadex/MusicOrganizer",
                            "https://raw.githubusercontent.com/kakadex/MusicOrganizer/main/dist/latest.txt"}),
    };

    private static final Map<String, String> DEFAULTS = new LinkedHashMap<String, String>();
    private static final Map<String, Source> BY_KEY = new HashMap<String, Source>();

    static {
        for (Source s : SOURCES) {
            BY_KEY.put(s.key, s);
            for (int i = 0; i < s.count(); i++) {
                DEFAULTS.put(s.endpointKey(i), s.defaultUrl(i));
            }
        }
    }

    // ------------------------------------------------------------------
    // 查询
    // ------------------------------------------------------------------

    /** 端点当前生效的地址（用户改过就用用户的）。 */
    public static String url(String endpointKey) {
        Config c = config;
        if (c != null) {
            String custom = c.override(endpointKey);
            if (custom != null) {
                custom = custom.trim();
                if (!custom.isEmpty()) {
                    return custom;
                }
            }
        }
        String def = DEFAULTS.get(endpointKey);
        return def == null ? "" : def;
    }

    /** 便捷写法：{@code url("netease", 0)}。 */
    public static String url(String sourceKey, int index) {
        return url(sourceKey + "." + index);
    }

    /** 端点是否被用户改过（界面上标「已修改」）。 */
    public static boolean customized(String endpointKey) {
        Config c = config;
        if (c == null) {
            return false;
        }
        String custom = c.override(endpointKey);
        return custom != null && !custom.trim().isEmpty();
    }

    public static String defaultUrl(String endpointKey) {
        String def = DEFAULTS.get(endpointKey);
        return def == null ? "" : def;
    }

    /** 源是否启用（未注入配置时一律启用）。 */
    public static boolean enabled(String sourceKey) {
        Config c = config;
        return c == null || c.enabled(sourceKey);
    }

    public static Source find(String sourceKey) {
        return BY_KEY.get(sourceKey);
    }

    /** 是否是已登记的端点键（如 {@code netease.0}）——设置备份导入时用来挡住乱写的键。 */
    public static boolean isEndpointKey(String endpointKey) {
        return endpointKey != null && DEFAULTS.containsKey(endpointKey);
    }

    /** 所有已登记的端点键（导出/文档用）。 */
    public static String[] endpointKeys() {
        return DEFAULTS.keySet().toArray(new String[0]);
    }

    /** 只接受 http/https，且不能带空格 —— 用户手输时最常见的两类错误。 */
    public static boolean isValidUrl(String url) {
        if (url == null) {
            return false;
        }
        String s = url.trim();
        if (s.isEmpty() || s.indexOf(' ') >= 0) {
            return false;
        }
        String lower = s.toLowerCase();
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            return false;
        }
        // 至少要有主机名
        int start = lower.startsWith("https://") ? 8 : 7;
        if (s.length() <= start) {
            return false;
        }
        char first = s.charAt(start);
        return first != '/' && first != '?';
    }

    /** 恢复所有端点的默认地址（不动启用开关）。 */
    public static void resetAll() {
        Config c = config;
        if (c == null) {
            return;
        }
        for (String key : DEFAULTS.keySet()) {
            c.setOverride(key, null);
        }
    }
}
