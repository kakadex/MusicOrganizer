package com.dsh.musicorganizer.core;

/**
 * 主题调色板 —— 三个方案（每个方案带「亮 / 暗」两套，暗色版为亮色的低亮度变体）。
 *
 * <p>三个方案：
 * <ol>
 *   <li><b>暖橙</b>：温润奶油底 #FFF7EC + 暖橙 #FF7A45，黑胶唱片质感；</li>
 *   <li><b>简紫</b>：纯净留白 + 靛蓝 #4F46E5 点缀（默认）；</li>
 *   <li><b>简蓝</b>：Material You 蓝调 #3D7BFF，圆润克制。</li>
 * </ol>
 *
 * <p>颜色是 {@code int}（{@code 0xAARRGGBB}），不依赖 android.graphics，纯 JVM 可测。
 */
public final class Theme {

    private Theme() {
    }

    public static final int WARM = 0;
    public static final int MINIMAL = 1;
    /** 亮蓝调（简蓝）。 */
    public static final int LYRICO = 2;

    public static final String[] NAMES = {"暖橙", "简紫", "简蓝"};

    /** 一组完整的界面配色。 */
    public static final class Palette {
        public final int bg;          // 页面背景
        public final int card;        // 卡片 / 面板背景
        public final int primary;     // 主色（按钮、选中、强调、进度）
        public final int primaryDark; // 主色深一档
        public final int primarySoft; // 主色的浅底（胶囊容器、待处理徽标底）
        public final int text;        // 主文字 / 标题
        public final int body;        // 正文
        public final int sub;         // 辅助 / caption
        public final int line;        // 分割线 / 描边
        public final int ok;
        public final int warn;
        public final int err;
        public final int accent;      // 点缀色（琥珀金 / 青 / 粉）

        Palette(int bg, int card, int primary, int primaryDark, int primarySoft,
                int text, int body, int sub, int line, int ok, int warn, int err, int accent) {
            this.bg = bg;
            this.card = card;
            this.primary = primary;
            this.primaryDark = primaryDark;
            this.primarySoft = primarySoft;
            this.text = text;
            this.body = body;
            this.sub = sub;
            this.line = line;
            this.ok = ok;
            this.warn = warn;
            this.err = err;
            this.accent = accent;
        }
    }

    public static String name(int themeId) {
        return themeId >= 0 && themeId < NAMES.length ? NAMES[themeId] : NAMES[MINIMAL];
    }

    /** 取某主题某明暗下的调色板。themeId 越界按「极简清感」处理。 */
    public static Palette palette(int themeId, boolean dark) {
        switch (themeId) {
            case WARM:
                return dark ? warmDark() : warmLight();
            case LYRICO:
                return dark ? lyricoDark() : lyricoLight();
            case MINIMAL:
            default:
                return dark ? minimalDark() : minimalLight();
        }
    }

    // ------------------------------------------------------------------
    // 暖橙黑胶
    // ------------------------------------------------------------------

    private static Palette warmLight() {
        return new Palette(
                0xFFFFF1E6, // bg 奶油底（设计稿 WARM_PALETTE）
                0xFFFFFFFF, // card
                0xFFFF7A45, // primary
                0xFFC75B2E, // primaryDark
                0xFFF5EBE0, // primarySoft（进度底 / 徽标底）
                0xFF2B2018, // text
                0xFF5A4A38, // body
                0xFF9A7B54, // sub
                0xFFEADBC8, // line
                0xFF3FA66A, 0xFFE0A100, 0xFFD64545, // ok/warn/err（设计稿 Success/Warning/Danger）
                0xFFE9C46A); // accent 琥珀金
    }

    private static Palette warmDark() {
        return new Palette(
                0xFF1E130D, 0xFF2A1C14,
                0xFFFF8A5C, 0xFFFF7A45, 0xFF3A261B,
                0xFFF7EBE0, 0xFFD9C6B4, 0xFFA99080, 0xFF3A2A20,
                0xFF4FBF82, 0xFFF0B429, 0xFFF0736C, // ok/warn/err（设计稿语义色提亮版）
                0xFFE9C46A);
    }

    // ------------------------------------------------------------------
    // 极简清感（默认）
    // ------------------------------------------------------------------

    private static Palette minimalLight() {
        return new Palette(
                0xFFF5F6FA, 0xFFFFFFFF,
                0xFF4F46E5, 0xFF3730A3, 0xFFEEF0F8,
                0xFF1A1C23, 0xFF3A3F52, 0xFF6B7194, 0xFFE3E6F0,
                0xFF10B981, 0xFFF59E0B, 0xFFEF4444, // ok/warn/err（设计稿）
                0xFF10B981);
    }

    private static Palette minimalDark() {
        return new Palette(
                0xFF13151C, 0xFF1C1E27,
                0xFF6C63FF, 0xFF4F46E5, 0xFF262A3D,
                0xFFE8EAF0, 0xFFC3C7D4, 0xFF9AA1B0, 0xFF2A2D3A,
                0xFF34D399, 0xFFFBBF24, 0xFFFB7185, // ok/warn/err（设计稿）
                0xFF34D399);
    }

    // ------------------------------------------------------------------
    // 简蓝（预览）：Material You 蓝调，圆润克制，强调色鲜明
    // 强调色取常见的亮蓝（#3D7BFF 一带），容器分浅/深两套
    // ------------------------------------------------------------------

    private static Palette lyricoLight() {
        return new Palette(
                0xFFF5F7FB, // bg 近白带冷调
                0xFFFFFFFF, // card
                0xFF3D7BFF, // primary 亮蓝
                0xFF2A5BE0, // primaryDark
                0xFFE6EEFF, // primarySoft 浅蓝底
                0xFF141A2E, // text
                0xFF3C445E, // body
                0xFF6B7280, // sub
                0xFFE4E8F2, // line
                0xFF1FA971, 0xFFF2A33C, 0xFFF0506E, // ok/warn/err
                0xFF3D7BFF); // accent 同主色
    }

    private static Palette lyricoDark() {
        return new Palette(
                0xFF0F1218, // bg 近黑带冷调
                0xFF181C25, // card
                0xFF5B8BFF, // primary 略提亮的蓝
                0xFF3D7BFF, // primaryDark
                0xFF1E2740, // primarySoft 深蓝底
                0xFFE9EDF6, // text
                0xFFB6BED4, // body
                0xFF8A91A6, // sub
                0xFF262B38, // line
                0xFF34D399, 0xFFFBBF24, 0xFFFB7185, // ok/warn/err
                0xFF5B8BFF); // accent
    }
}
