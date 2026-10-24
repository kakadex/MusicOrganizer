import com.dsh.musicorganizer.core.Theme;

/**
 * 主题调色板回归测试（纯 JVM）。
 *
 * 覆盖：三个方案的亮/暗色值精确还原《品牌设计三方案》原型数值、越界兜底、name()。
 */
public final class ThemeTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        section("暖橙");
        Theme.Palette wa = Theme.palette(Theme.WARM, false);
        check("亮色主色 #FF7A45", wa.primary == 0xFFFF7A45);
        check("亮色背景 #FFF1E6（设计稿）", wa.bg == 0xFFFFF1E6);
        check("亮色成功 #3FA66A", wa.ok == 0xFF3FA66A);
        check("亮色警告 #E0A100", wa.warn == 0xFFE0A100);
        check("亮色危险 #D64545", wa.err == 0xFFD64545);
        check("亮色深橙 #C75B2E", wa.primaryDark == 0xFFC75B2E);
        check("亮色文字 #2B2018", wa.text == 0xFF2B2018);
        Theme.Palette wd = Theme.palette(Theme.WARM, true);
        check("暗色主色更亮", wd.primary != wa.primary);
        check("暗色背景更暗", wd.bg < wa.bg);
        check("暗色文字更亮", wd.text > wa.text);

        section("简紫（默认）");
        Theme.Palette ml = Theme.palette(Theme.MINIMAL, false);
        check("亮色主色 #4F46E5", ml.primary == 0xFF4F46E5);
        check("亮色文字 #1A1C23", ml.text == 0xFF1A1C23);
        check("亮色 accent #10B981", ml.accent == 0xFF10B981);
        check("极简警告 #F59E0B", ml.warn == 0xFFF59E0B);
        check("极简危险 #EF4444", ml.err == 0xFFEF4444);
        check("极简警告 #F59E0B", ml.warn == 0xFFF59E0B);
        check("极简危险 #EF4444", ml.err == 0xFFEF4444);

        section("简蓝");
        Theme.Palette ld = Theme.palette(Theme.LYRICO, true);
        check("暗色主色 #5B8BFF", ld.primary == 0xFF5B8BFF);
        check("暗色背景 #0F1218", ld.bg == 0xFF0F1218);
        Theme.Palette ll = Theme.palette(Theme.LYRICO, false);
        check("亮色主色 #3D7BFF", ll.primary == 0xFF3D7BFF);
        check("亮色背景 #F5F7FB", ll.bg == 0xFFF5F7FB);

        section("越界与名称");
        Theme.Palette fallback = Theme.palette(99, false);
        check("越界按简紫处理", fallback.primary == 0xFF4F46E5);
        check("name(0)", "暖橙".equals(Theme.name(Theme.WARM)));
        check("name(1)", "简紫".equals(Theme.name(Theme.MINIMAL)));
        check("name(2)", "简蓝".equals(Theme.name(Theme.LYRICO)));
        check("name 越界兜底", "简紫".equals(Theme.name(99)));

        section("对比度（v0.1.53 夜间可读性）");
        // 这一节防的是「配色改一改，暗色模式变成浅字浅底看不清」。
        // 阈值按 WCAG 折算：正文/卡片 ≥ 8（远高于 AA 的 4.5，因为列表用 13sp 小字），
        // 辅助文字（caption / 标签名）≥ 3.5，主文字 ≥ 12。
        for (int i = 0; i < Theme.NAMES.length; i++) {
            Theme.Palette light = Theme.palette(i, false);
            Theme.Palette dark = Theme.palette(i, true);
            check(Theme.name(i) + " 亮色 主文字/卡片 ≥ 12",
                    contrast(light.text, light.card) >= 12.0);
            check(Theme.name(i) + " 亮色 正文/卡片 ≥ 8",
                    contrast(light.body, light.card) >= 8.0);
            check(Theme.name(i) + " 亮色 辅助/卡片 ≥ 3.5",
                    contrast(light.sub, light.card) >= 3.5);
            check(Theme.name(i) + " 暗色 主文字/卡片 ≥ 12",
                    contrast(dark.text, dark.card) >= 12.0);
            check(Theme.name(i) + " 暗色 正文/卡片 ≥ 8",
                    contrast(dark.body, dark.card) >= 8.0);
            check(Theme.name(i) + " 暗色 辅助/卡片 ≥ 3.5",
                    contrast(dark.sub, dark.card) >= 3.5);
            // 反过来也要防：暗色主题的文字不能比底色更暗（说明抄错了表）
            check(Theme.name(i) + " 暗色 文字比底色亮",
                    (dark.text & 0xFFFFFF) > (dark.card & 0xFFFFFF));
            check(Theme.name(i) + " 亮色 文字比底色暗",
                    (light.text & 0xFFFFFF) < (light.card & 0xFFFFFF));
        }

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    /** WCAG 相对亮度对比度（1.0 起，21.0 最高）。 */
    private static double contrast(int a, int b) {
        double la = luminance(a);
        double lb = luminance(b);
        double hi = Math.max(la, lb);
        double lo = Math.min(la, lb);
        return (hi + 0.05) / (lo + 0.05);
    }

    private static double luminance(int color) {
        double r = channel((color >> 16) & 0xFF);
        double g = channel((color >> 8) & 0xFF);
        double b = channel(color & 0xFF);
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    private static double channel(int value) {
        double v = value / 255.0;
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
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
}
