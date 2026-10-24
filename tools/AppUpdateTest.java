import com.dsh.musicorganizer.core.AppUpdate;

/**
 * 更新检查内核回归测试（纯 JVM）。
 *
 * 覆盖：
 *   1. 版本号归一（v 前缀 / 空白 / 多段 / 垃圾输入）
 *   2. 逐段比较（0.1.10 > 0.1.9，1.0 == 1.0.0，预发布 < 正式版）
 *   3. isNewer / display
 *   4. GitHub Release JSON 解析（正常 / 缺字段 / 非 JSON / HTML 错误页 / 多资产）
 *   5. Release 说明美化（去 Markdown 标记、截断）
 *   6. 字节数格式化
 */
public final class AppUpdateTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        normalize();
        compareVersions();
        newerAndDisplay();
        parseReleaseJson();
        notesCleanup();
        sizes();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void normalize() {
        section("版本号归一");
        expect("v 前缀去掉", "0.1.10", AppUpdate.normalize("v0.1.10"));
        expect("大写 V", "0.1.10", AppUpdate.normalize("V0.1.10"));
        expect("首尾空白", "0.1.10", AppUpdate.normalize("  v0.1.10 \n"));
        expect("两段保留", "2.3", AppUpdate.normalize("2.3"));
        expect("多余分隔符折叠", "0.1.11", AppUpdate.normalize("0-1-11"));
        expect("日期型 tag", "2026.10.22", AppUpdate.normalize("release-2026-10-22"));
        expect("最多四段", "1.2.3.4", AppUpdate.normalize("1.2.3.4.5.6"));
        expect("没有数字给空串", "", AppUpdate.normalize("latest"));
        expect("null 给空串", "", AppUpdate.normalize(null));
    }

    private static void compareVersions() {
        section("版本比较");
        check("0.1.10 > 0.1.9", AppUpdate.compare("0.1.10", "0.1.9") > 0);
        check("0.1.9 < 0.1.10", AppUpdate.compare("0.1.9", "0.1.10") < 0);
        check("0.1.10 == 0.1.10", AppUpdate.compare("0.1.10", "0.1.10") == 0);
        check("带 v 与不带 v 相同", AppUpdate.compare("v0.1.10", "0.1.10") == 0);
        check("1.0 == 1.0.0", AppUpdate.compare("1.0", "1.0.0") == 0);
        check("1.0.1 > 1.0", AppUpdate.compare("1.0.1", "1.0") > 0);
        check("0.2.0 > 0.1.99", AppUpdate.compare("0.2.0", "0.1.99") > 0);
        check("10.0 > 9.9", AppUpdate.compare("10.0", "9.9") > 0);
        check("预发布更旧：0.2.0-beta < 0.2.0",
                AppUpdate.compare("0.2.0-beta", "0.2.0") < 0);
        check("预发布更旧：0.2.0 < 0.2.0-rc1",
                AppUpdate.compare("0.2.0", "0.2.0-rc1") > 0);
        // 预发布后缀里的数字刻意不算版本段（否则 0.2.0-rc1 会“比 0.2.0 新”）
        check("beta1 与 beta2 视为同一版",
                AppUpdate.compare("0.2.0-beta2", "0.2.0-beta1") == 0);
        check("垃圾输入不抛异常（当 0）",
                AppUpdate.compare("abc", "0") == 0);
        check("本机 0.1.10 对远端 0.1.10 不算新",
                !AppUpdate.isNewer("0.1.10", "v0.1.10"));
    }

    private static void newerAndDisplay() {
        section("isNewer / display");
        check("远端更新", AppUpdate.isNewer("0.1.10", "v0.1.11"));
        check("远端更旧不算", !AppUpdate.isNewer("0.1.11", "v0.1.10"));
        check("远端为空不算", !AppUpdate.isNewer("0.1.10", ""));
        check("远端为 null 不算", !AppUpdate.isNewer("0.1.10", null));
        expect("display 补 v", "v0.1.11", AppUpdate.display("v0.1.11"));
        expect("display 归一数字", "v0.1.11", AppUpdate.display("0.1.11"));
        expect("display 空版本回原文", "latest", AppUpdate.display("latest"));
    }

    private static void parseReleaseJson() {
        section("Release 解析");

        String full = "{"
                + "\"tag_name\":\"v0.1.11\","
                + "\"name\":\"v0.1.11 GitHub 更新检查\","
                + "\"body\":\"## 新增\\n- 检查更新\\n\","
                + "\"html_url\":\"https://github.com/kakadex/MusicOrganizer/releases/tag/v0.1.11\","
                + "\"published_at\":\"2026-10-23T01:00:00Z\","
                + "\"prerelease\":false,\"draft\":false,"
                + "\"assets\":["
                + "{\"name\":\"notes.md\",\"size\":1024,"
                + "\"browser_download_url\":\"https://example.com/notes.md\"},"
                + "{\"name\":\"音乐整理工具-v0.1.11.apk\",\"size\":235000,"
                + "\"browser_download_url\":\"https://example.com/%E9%9F%B3%E4%B9%90-v0.1.11.apk\"}"
                + "]}";
        AppUpdate.Release r = AppUpdate.parseRelease(full);
        check("解析成功", r != null);
        if (r != null) {
            expect("tag 原样", "v0.1.11", r.tag);
            expect("version 归一", "0.1.11", r.version);
            expect("标题", "v0.1.11 GitHub 更新检查", r.title);
            check("有说明", r.notes.contains("检查更新"));
            check("发布页", r.pageUrl.endsWith("/v0.1.11"));
            check("跳过非 apk 资产", r.apkUrl.contains(".apk"));
            expect("apk 文件名", "音乐整理工具-v0.1.11.apk", r.apkName);
            check("apk 大小", r.apkSize == 235000L);
            check("hasApk", r.hasApk());
            check("非预发布", !r.prerelease);
            expect("发布时间", "2026-10-23T01:00:00Z", r.publishedAt);
        }

        // 没有资产（早期 release 只挂 tag）
        String noAssets = "{\"tag_name\":\"v0.1.2\",\"name\":\"\",\"body\":\"\","
                + "\"html_url\":\"https://example.com/r\",\"assets\":[]}";
        AppUpdate.Release r2 = AppUpdate.parseRelease(noAssets);
        check("无资产也能解析", r2 != null);
        if (r2 != null) {
            check("无 apk 链接", !r2.hasApk());
            expect("空标题回落 tag", "v0.1.2", r2.title);
        }

        // 缺 tag_name：GitHub 报错时给的是 {"message":"Not Found"}
        check("缺 tag_name 返回 null",
                AppUpdate.parseRelease("{\"message\":\"Not Found\"}") == null);
        check("HTML 错误页返回 null",
                AppUpdate.parseRelease("<html><body>403</body></html>") == null);
        check("空串返回 null", AppUpdate.parseRelease("") == null);
        check("null 返回 null", AppUpdate.parseRelease(null) == null);
        check("数组不是对象返回 null", AppUpdate.parseRelease("[1,2,3]") == null);

        // 预发布标记
        AppUpdate.Release pre = AppUpdate.parseRelease(
                "{\"tag_name\":\"v0.2.0-beta\",\"prerelease\":true,\"assets\":[]}");
        check("识别预发布", pre != null && pre.prerelease);
        check("预发布版本比正式版旧",
                pre != null && AppUpdate.compare(pre.version, "0.2.0") < 0);
    }

    private static void notesCleanup() {
        section("说明美化");

        String md = "## 新增\n"
                + "- **检查更新**：点顶栏版本号即可\n"
                + "- 下载走浏览器 [发布页](https://example.com/r)\n"
                + "\n"
                + "## 修复\n"
                + "- `TaskService` 启动崩溃\n"
                + "---\n"
                + "> 备注：需要 Android 7.0+";
        String out = AppUpdate.shortNotes(md, 20);
        check("标题变成【】", out.contains("【新增】"));
        check("去掉粗体星号", !out.contains("**"));
        check("去掉行内反引号", !out.contains("`"));
        check("链接只留文字", out.contains("发布页") && !out.contains("https://example.com/r"));
        check("保留列表符号", out.contains("- 检查更新"));
        check("分隔线被丢掉", !out.contains("---"));
        check("引用块去掉 >", !out.contains(">"));

        // 行数截断
        StringBuilder many = new StringBuilder();
        for (int i = 0; i < 60; i++) {
            many.append("- 第 ").append(i).append(" 条改动\n");
        }
        String cut = AppUpdate.shortNotes(many.toString(), 5);
        int lines = cut.split("\n").length;
        check("行数被截断（含省略号行）", lines <= 6);
        check("截断处有省略号", cut.contains("…"));

        // 超长单行
        StringBuilder huge = new StringBuilder();
        for (int i = 0; i < 400; i++) {
            huge.append("很长的说明");
        }
        String longOut = AppUpdate.shortNotes(huge.toString(), 20);
        check("超长内容被截到 900 字以内", longOut.length() < 1100);

        check("空说明返回空串", AppUpdate.shortNotes(null, 10).isEmpty());
        check("全空白说明返回空串", AppUpdate.shortNotes("  \n\n  ", 10).isEmpty());
        check("代码围栏标记被丢掉",
                !AppUpdate.shortNotes("```\ncode\n```", 10).contains("```"));
    }

    private static void sizes() {
        section("大小格式化");
        expect("0 给空串", "", AppUpdate.humanSize(0));
        expect("负数给空串", "", AppUpdate.humanSize(-5));
        expect("小字节", "512 B", AppUpdate.humanSize(512));
        expect("KB", "1 KB", AppUpdate.humanSize(1024));
        expect("MB 一位小数", "1.5 MB", AppUpdate.humanSize(1024L * 1024 * 3 / 2));
        expect("APK 常见大小（KB 取整）", "235 KB", AppUpdate.humanSize(240435));

        // ---- 版本清单（dist/latest.txt，国内镜像主通道，v0.1.78）----
        section("版本清单解析");
        String gitee = "https://gitee.com/kakadex/MusicOrganizer/raw/main/dist/latest.txt";
        String gh = "https://raw.githubusercontent.com/kakadex/MusicOrganizer/main/dist/latest.txt";
        String txt = "# 注释行\n"
                + "version=0.1.78-ab12cd\n"
                + "code=88\n"
                + "tag=v0.1.78-ab12cd\n"
                + "apk=dist/musicorganizer-latest.apk\n"
                + "size=357839\n"
                + "summary=v0.1.78-ab12cd — 修正码率显示\n"
                + "page=https://gitee.com/kakadex/MusicOrganizer/releases\n"
                + "date=2026-10-25\n";
        AppUpdate.Release r = AppUpdate.parseManifest(txt, gitee);
        check("清单能解析", r != null);
        expect("tag 正确", "v0.1.78-ab12cd", r.tag);
        expect("版本去除前缀", "0.1.78-ab12cd", r.version);
        check("体积正确", r.apkSize == 357839L);
        check("有 APK 直链", r.hasApk());
        expect("Gitee 相对路径拼成绝对直链",
                "https://gitee.com/kakadex/MusicOrganizer/raw/main/dist/musicorganizer-latest.apk",
                r.apkUrl);
        expect("APK 文件名", "musicorganizer-latest.apk", r.apkName);
        expect("发布页原样保留", "https://gitee.com/kakadex/MusicOrganizer/releases", r.pageUrl);
        check("说明取 summary", r.notes.contains("修正码率显示"));
        check("不是预发布", !r.prerelease);
        check("比 0.1.77 新", AppUpdate.isNewer("0.1.77-volb2t", r.version));

        // GitHub raw 的清单地址接出来的直链也要跟着换域名
        AppUpdate.Release r2 = AppUpdate.parseManifest(txt, gh);
        expect("GitHub 直链域名正确",
                "https://raw.githubusercontent.com/kakadex/MusicOrganizer/main/dist/musicorganizer-latest.apk",
                r2 == null ? "" : r2.apkUrl);

        // 只有 version、没有 tag：自动补 v 前缀
        AppUpdate.Release r3 = AppUpdate.parseManifest("version=0.1.79\napk=dist/a.apk\n", gitee);
        expect("缺 tag 时自动补", "v0.1.79", r3 == null ? "" : r3.tag);
        check("带 -rc 的算预发布",
                AppUpdate.parseManifest("version=0.2.0-rc1\n", gitee).prerelease);

        // 容错：HTML 错误页 / 空内容 / 垃圾文本一律返回 null（不能当成"已是最新"）
        check("HTML 返回 null",
                AppUpdate.parseManifest("<html>404</html>", gitee) == null);
        check("空串返回 null", AppUpdate.parseManifest("", gitee) == null);
        check("null 返回 null", AppUpdate.parseManifest(null, gitee) == null);
        check("只有注释返回 null",
                AppUpdate.parseManifest("# 什么都没有\n", gitee) == null);

        // 绝对地址原样保留；清单地址缺失时相对路径给空串（调用方会退回发布页）
        expect("绝对 apk 地址原样",
                "https://cdn.example.com/a.apk",
                AppUpdate.resolve(gitee, "https://cdn.example.com/a.apk"));
        expect("没有清单地址时给空串", "", AppUpdate.resolve("", "dist/a.apk"));
    }

    // ------------------------------------------------------------------

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
