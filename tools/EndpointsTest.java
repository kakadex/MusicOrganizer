import com.dsh.musicorganizer.net.Endpoints;

import java.util.HashMap;
import java.util.Map;

/**
 * 接口地址注册表回归测试（纯 JVM）。
 *
 * 覆盖：
 *   1. 未注入配置时返回默认地址
 *   2. 用户覆盖生效；覆盖为空串时回落默认
 *   3. 启用开关默认开启、可关闭
 *   4. resetAll 清空所有覆盖
 *   5. 地址校验（http/https、空格、缺主机）
 */
public final class EndpointsTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        defaultsWithoutConfig();
        overrideWorks();
        enableSwitch();
        resetAllClears();
        urlValidation();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void defaultsWithoutConfig() {
        section("默认地址（未注入配置）");
        Endpoints.uninstall();
        expect("网易云默认", "https://music.163.com/api/search/get",
                Endpoints.url("netease", 0));
        expect("酷我默认", "https://search.kuwo.cn/r.s", Endpoints.url("kuwo", 0));
        expect("QQ 歌词第二个端点",
                "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                Endpoints.url("lyric_qq", 1));
        check("未知键返回空串", Endpoints.url("nope", 0).isEmpty());
        check("默认全部启用", Endpoints.enabled("netease"));
        // v0.1.41 新增 lyric_kugou（13→14）；v0.1.78 新增 gitee 更新源（14→15）
        check("源数量为 15", Endpoints.SOURCES.length == 15);
        check("未注入时 customized=false", !Endpoints.customized("netease.0"));
        // 更新检查也是「可改地址的源」：GitHub 连不上时用户可以换镜像
        expect("GitHub 最新版本接口",
                "https://api.github.com/repos/kakadex/MusicOrganizer/releases/latest",
                Endpoints.url("update", 0));
        expect("GitHub 发布页",
                "https://github.com/kakadex/MusicOrganizer/releases/latest",
                Endpoints.url("update", 1));
        expect("GitHub 仓库主页",
                "https://github.com/kakadex/MusicOrganizer", Endpoints.url("update", 2));
        check("update 源已登记为端点键", Endpoints.isEndpointKey("update.0"));
    }

    private static void overrideWorks() {
        section("用户覆盖地址");
        FakeConfig cfg = new FakeConfig();
        Endpoints.install(cfg);

        expect("未改过仍用默认", "https://search.kuwo.cn/r.s", Endpoints.url("kuwo", 0));
        cfg.setOverride("kuwo.0", "https://mirror.example.com/kw");
        expect("改过之后生效", "https://mirror.example.com/kw", Endpoints.url("kuwo", 0));
        check("标记为已修改", Endpoints.customized("kuwo.0"));
        expect("其它端点不受影响", "https://music.163.com/api/search/get",
                Endpoints.url("netease", 0));

        cfg.setOverride("kuwo.0", "   ");
        expect("覆盖为空白则回落默认", "https://search.kuwo.cn/r.s", Endpoints.url("kuwo", 0));
        check("空白覆盖不算已修改", !Endpoints.customized("kuwo.0"));

        cfg.setOverride("kuwo.0", "  https://x.example.com/a  ");
        expect("保存时去掉首尾空格", "https://x.example.com/a", Endpoints.url("kuwo", 0));
    }

    private static void enableSwitch() {
        section("启用开关");
        FakeConfig cfg = new FakeConfig();
        Endpoints.install(cfg);
        check("默认启用", Endpoints.enabled("migu"));
        cfg.setEnabled("migu", false);
        check("可以关掉", !Endpoints.enabled("migu"));
        check("只影响该源", Endpoints.enabled("kuwo"));
        cfg.setEnabled("migu", true);
        check("可以再打开", Endpoints.enabled("migu"));
    }

    private static void resetAllClears() {
        section("恢复默认");
        FakeConfig cfg = new FakeConfig();
        Endpoints.install(cfg);
        cfg.setOverride("netease.0", "https://a.example.com/x");
        cfg.setOverride("lrclib.1", "https://b.example.com/y");
        cfg.setEnabled("kugou", false);
        Endpoints.resetAll();
        expect("netease 回到默认", "https://music.163.com/api/search/get",
                Endpoints.url("netease", 0));
        expect("lrclib 第二端点回到默认", "https://lrclib.net/api/search",
                Endpoints.url("lrclib", 1));
        check("恢复默认不改启用状态", !Endpoints.enabled("kugou"));
    }

    private static void urlValidation() {
        section("地址校验");
        check("https 合法", Endpoints.isValidUrl("https://a.example.com/x"));
        check("http 合法", Endpoints.isValidUrl("http://a.example.com"));
        check("首尾空格容忍", Endpoints.isValidUrl("  https://a.example.com/x "));
        check("非 http 拒绝", !Endpoints.isValidUrl("ftp://a.example.com"));
        check("没有协议拒绝", !Endpoints.isValidUrl("a.example.com/x"));
        check("中间空格拒绝", !Endpoints.isValidUrl("https://a example.com"));
        check("空串拒绝", !Endpoints.isValidUrl(""));
        check("null 拒绝", !Endpoints.isValidUrl(null));
        check("没有主机名拒绝", !Endpoints.isValidUrl("https://"));
        check("只有斜杠拒绝", !Endpoints.isValidUrl("https:///path"));
    }

    // ------------------------------------------------------------------

    /** 内存版配置，模拟 SharedPreferences。 */
    private static final class FakeConfig implements Endpoints.Config {
        final Map<String, String> urls = new HashMap<String, String>();
        final Map<String, Boolean> on = new HashMap<String, Boolean>();

        @Override
        public String override(String endpointKey) {
            return urls.get(endpointKey);
        }

        @Override
        public boolean enabled(String sourceKey) {
            Boolean v = on.get(sourceKey);
            return v == null || v;
        }

        @Override
        public void setOverride(String endpointKey, String url) {
            if (url == null || url.trim().isEmpty()) {
                urls.remove(endpointKey);
            } else {
                urls.put(endpointKey, url.trim());
            }
        }

        @Override
        public void setEnabled(String sourceKey, boolean enabled) {
            on.put(sourceKey, enabled);
        }
    }

    private static void section(String title) {
        System.out.println("[ " + title + " ]");
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("  ok   " + name);
        } else {
            failed++;
            System.out.println("  FAIL " + name);
        }
    }

    private static void expect(String name, String expected, String actual) {
        boolean ok = expected.equals(actual);
        check(name + (ok ? "" : "（期望 " + expected + "，实际 " + actual + "）"), ok);
    }
}
