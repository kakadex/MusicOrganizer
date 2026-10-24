package com.dsh.musicorganizer.ui;

import com.dsh.musicorganizer.R;
import com.dsh.musicorganizer.core.Theme;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;

/**
 * UI 小工具：卡片、按钮、间距（全部程序化构建，不用 XML 布局）。
 *
 * <p>颜色统一走 {@link Theme} 调色板 —— 三个品牌方案（暖橙黑胶 / 极简清感 / 霓虹脉冲）
 * 各带亮 / 暗两套，{@link #install} 切换后所有组件即时换色。
 */
public final class UiKit {

    private UiKit() {
    }

    // ------------------------------------------------------------------
    // 主题状态（install 由 MainActivity 启动时调用，切换后 recreate 生效）
    // ------------------------------------------------------------------

    private static int themeId = Theme.MINIMAL;
    private static boolean dark = false;
    private static Theme.Palette palette = Theme.palette(Theme.MINIMAL, false);

    public static void install(int id, boolean darkMode) {
        themeId = id;
        dark = darkMode;
        palette = Theme.palette(id, darkMode);
    }

    public static Theme.Palette palette() {
        return palette;
    }

    public static boolean isDark() {
        return dark;
    }

    public static int themeId() {
        return themeId;
    }

    // 便捷取色（供各处调用点与 sed 替换后的代码使用）
    public static int textColor() {
        return palette.text;
    }

    public static int bodyColor() {
        return palette.body;
    }

    public static int subColor() {
        return palette.sub;
    }

    public static int cardColor() {
        return palette.card;
    }

    public static int bgColor() {
        return palette.bg;
    }

    public static int lineColor() {
        return palette.line;
    }

    public static int primary() {
        return palette.primary;
    }

    public static int primaryDark() {
        return palette.primaryDark;
    }

    public static int primarySoft() {
        return palette.primarySoft;
    }

    public static int accentColor() {
        return palette.accent;
    }

    public static int okColor() {
        return palette.ok;
    }

    public static int warnColor() {
        return palette.warn;
    }

    public static int errColor() {
        return palette.err;
    }

    public static int dp(Context ctx, float value) {
        return Math.round(value * ctx.getResources().getDisplayMetrics().density);
    }

    public static LinearLayout vertical(Context ctx) {
        LinearLayout v = new LinearLayout(ctx);
        v.setOrientation(LinearLayout.VERTICAL);
        return v;
    }

    public static LinearLayout horizontal(Context ctx) {
        LinearLayout v = new LinearLayout(ctx);
        v.setOrientation(LinearLayout.HORIZONTAL);
        return v;
    }

    /** 圆角卡片容器。 */
    public static LinearLayout card(Context ctx) {
        LinearLayout card = vertical(ctx);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(palette.card);
        bg.setCornerRadius(dp(ctx, 18));
        bg.setStroke(dp(ctx, 1), palette.line);
        card.setBackground(bg);
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            card.setElevation(dp(ctx, 3));
            // 投影染上一点主色，贴近 Material You 的观感
            if (android.os.Build.VERSION.SDK_INT >= 28) {
                card.setOutlineAmbientShadowColor(shade(palette.primary, 0.55f));
                card.setOutlineSpotShadowColor(shade(palette.primary, 0.40f));
            }
        }
        int pad = dp(ctx, 16);
        card.setPadding(pad, pad, pad, pad);
        return card;
    }

    public static TextView text(Context ctx, String value, float sizeSp, int color, boolean bold) {
        TextView tv = new TextView(ctx);
        tv.setText(value);
        tv.setTextSize(sizeSp);
        tv.setTextColor(color);
        if (bold) {
            tv.setTypeface(Typeface.DEFAULT_BOLD);
        }
        return tv;
    }

    public static TextView caption(Context ctx, String value) {
        return text(ctx, value, 12.5f, subColor(), false);
    }

    public static Button button(Context ctx, String label, boolean primary) {
        Button b = new Button(ctx);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(14.5f);
        // Material You 风：胶囊形、足够高的触摸区（主操作 48dp、次操作 40dp）
        int h = dp(ctx, primary ? 48 : 40);
        b.setMinHeight(h);
        b.setMinimumHeight(h);
        b.setPadding(dp(ctx, 20), dp(ctx, 11), dp(ctx, 20), dp(ctx, 11));
        b.setBackground(buttonBg(ctx, primary));
        if (primary) {
            b.setTextColor(Color.WHITE);
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                b.setStateListAnimator(null);
                b.setElevation(dp(ctx, 2));
            }
        } else {
            b.setTextColor(palette.primary);
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                b.setStateListAnimator(null);
            }
        }
        return b;
    }

    /**
     * 悬浮操作按钮（FAB）：圆形主色底 + 居中符号，右下角圆形按钮。
     *
     * <p>尺寸 / 位置由调用方用 {@code FrameLayout.LayoutParams} 指定（一般 56dp、
     * {@code Gravity.BOTTOM|END}）；这里只负责圆形外观、主色、投影与文字。
     */
    public static TextView fab(Context ctx, String symbol) {
        TextView fab = new TextView(ctx);
        fab.setText(symbol);
        fab.setTextSize(26);
        fab.setTextColor(Color.WHITE);
        fab.setGravity(android.view.Gravity.CENTER);
        fab.setIncludeFontPadding(false);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(palette.primary);
        fab.setBackground(bg);
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            fab.setElevation(dp(ctx, 6));
            if (android.os.Build.VERSION.SDK_INT >= 28) {
                fab.setOutlineAmbientShadowColor(shade(palette.primary, 0.45f));
                fab.setOutlineSpotShadowColor(shade(palette.primary, 0.35f));
            }
        }
        return fab;
    }

    /** 胶囊形按钮背景：按下时换深一档色，松开回弹（无外部资源依赖）。 */
    private static android.graphics.drawable.Drawable buttonBg(Context ctx, boolean primary) {
        float r = dp(ctx, 999);
        GradientDrawable normal = new GradientDrawable();
        normal.setCornerRadius(r);
        GradientDrawable pressed = new GradientDrawable();
        pressed.setCornerRadius(r);
        if (primary) {
            normal.setColor(palette.primary);
            pressed.setColor(palette.primaryDark);
        } else {
            normal.setColor(palette.primarySoft);
            pressed.setColor(shade(palette.primarySoft, 0.90f));
        }
        android.graphics.drawable.StateListDrawable st =
                new android.graphics.drawable.StateListDrawable();
        st.addState(new int[]{android.R.attr.state_pressed}, pressed);
        st.addState(new int[]{}, normal);
        return st;
    }

    /** 颜色提亮 / 压暗（factor>1 提亮，<1 压暗），保留 alpha。 */
    private static int shade(int color, float factor) {
        int a = (color >> 24) & 0xFF;
        int r = Math.min(255, (int) (((color >> 16) & 0xFF) * factor));
        int g = Math.min(255, (int) (((color >> 8) & 0xFF) * factor));
        int b = Math.min(255, (int) ((color & 0xFF) * factor));
        return (a << 24) | (r << 16) | (g << 8) | b;
    }

    public static CheckBox checkbox(Context ctx, String label, boolean checked) {
        CheckBox cb = new CheckBox(ctx);
        cb.setText(label);
        cb.setTextSize(14);
        cb.setTextColor(textColor());
        cb.setChecked(checked);
        return cb;
    }

    public static EditText input(Context ctx, String hint) {
        EditText et = new EditText(ctx);
        et.setHint(hint);
        et.setTextSize(14);
        et.setTextColor(textColor());
        et.setHintTextColor(subColor());
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(palette.bg);
        bg.setCornerRadius(dp(ctx, 10));
        bg.setStroke(dp(ctx, 1), palette.line);
        et.setBackground(bg);
        int pad = dp(ctx, 10);
        et.setPadding(pad, pad, pad, pad);
        return et;
    }

    /**
     * 带主题的 {@link android.app.AlertDialog.Builder}（v0.1.53）。
     *
     * <p>用法与系统 Builder 完全一样，只是 {@code show()} 之后会自动把窗口底色、标题、
     * 按钮刷成当前主题色。这样二级 / 三级页面不需要各自记得配色 —— 颜色只在一处定义、子页面继承。
     *
     * <p>注意：走 {@code create()} 再自己 {@code show()} 的写法不会自动上色，
     * 那条路要手动补一句 {@link #tintDialog}。
     */
    public static final class Builder extends android.app.AlertDialog.Builder {

        public Builder(Context ctx) {
            super(ctx);
        }

        public Builder(Context ctx, int themeResId) {
            super(ctx, themeResId);
        }

        @Override
        public android.app.AlertDialog show() {
            android.app.AlertDialog dialog = super.show();
            tintDialog(dialog);
            return dialog;
        }
    }

    /**
     * 让系统 {@link android.app.AlertDialog} 的窗口底色 / 标题 / 按钮跟随应用主题（v0.1.53）。
     *
     * <p>为什么要这一步：对话框的底色与标题是**系统按 Activity 主题画的**，而正文文字是我们
     * 自己 {@link #text} 按主题取色的。夜间模式下如果只改前者或只改后者，就会出现
     * 「白底浅字」或「深底深字」。这里把窗口底色换成卡片色、标题与按钮换成主题色，
     * 正文（已有颜色）就能正常读。
     *
     * <p>必须在 {@code show()} 之后调用：{@code getButton()} 要等对话框建好视图才拿得到。
     */
    public static void tintDialog(android.app.AlertDialog dialog) {
        if (dialog == null) {
            return;
        }
        Context ctx = dialog.getContext();
        android.view.Window window = dialog.getWindow();
        if (window != null) {
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(palette.card);
            bg.setCornerRadius(dp(ctx, 16));
            bg.setStroke(dp(ctx, 1), palette.line);
            // 必须套一层 InsetDrawable：系统默认底板自带边距，直接换成自己的 shape
            // 会让弹窗贴到屏幕两边（窄屏上尤其明显）。
            window.setBackgroundDrawable(new android.graphics.drawable.InsetDrawable(
                    bg, dp(ctx, 16), dp(ctx, 8), dp(ctx, 16), dp(ctx, 8)));
        }
        // 标题：系统用 textColorPrimary，暗色主题下已经是浅色，但换成主题正文色更统一
        int titleId = ctx.getResources().getIdentifier("alertTitle", "id", "android");
        if (titleId != 0) {
            TextView title = dialog.findViewById(titleId);
            if (title != null) {
                title.setTextColor(palette.text);
            }
        }
        int[] buttons = {android.app.AlertDialog.BUTTON_POSITIVE,
                android.app.AlertDialog.BUTTON_NEGATIVE,
                android.app.AlertDialog.BUTTON_NEUTRAL};
        for (int which : buttons) {
            Button b = dialog.getButton(which);
            if (b != null) {
                b.setTextColor(palette.primary);
            }
        }
    }

    /** 0~max 的滑块（用于权重这类百分比参数）。 */    public static SeekBar slider(Context ctx, int value, int max) {
        SeekBar sb = new SeekBar(ctx);
        sb.setMax(max > 0 ? max : 1);
        sb.setProgress(Math.max(0, Math.min(value, sb.getMax())));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, dp(ctx, 2), 0, dp(ctx, 2));
        sb.setLayoutParams(lp);
        return sb;
    }

    public static void margin(View v, int left, int top, int right, int bottom) {
        LinearLayout.LayoutParams lp;
        if (v.getLayoutParams() instanceof LinearLayout.LayoutParams) {
            lp = (LinearLayout.LayoutParams) v.getLayoutParams();
        } else {
            lp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
        }
        lp.setMargins(dp(v.getContext(), left), dp(v.getContext(), top),
                dp(v.getContext(), right), dp(v.getContext(), bottom));
        v.setLayoutParams(lp);
    }

    // ------------------------------------------------------------------
    // 列表 / 筛选 / 折叠区（v0.1.10 起界面三块共用）
    // ------------------------------------------------------------------

    public static View divider(Context ctx) {
        View v = new View(ctx);
        v.setBackgroundColor(palette.line);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, Math.max(1, dp(ctx, 1)));
        lp.setMargins(0, dp(ctx, 8), 0, dp(ctx, 8));
        v.setLayoutParams(lp);
        return v;
    }

    /** 小徽标（「无封面」「待补 3 项」这类）。颜色是文字色，底色自动调淡。 */
    public static TextView badge(Context ctx, String label, int color) {
        TextView tv = text(ctx, label, 10.5f, color, false);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor((color & 0x00FFFFFF) | (dark ? 0x2EFFFFFF : 0x1A000000));
        bg.setCornerRadius(dp(ctx, 6));
        tv.setBackground(bg);
        int padH = dp(ctx, 5);
        tv.setPadding(padH, dp(ctx, 1), padH, dp(ctx, 1));
        return tv;
    }

    /** 可点的小胶囊（筛选 / 排序入口）。checked 时反白。 */
    public static TextView chip(Context ctx, String label, boolean checked) {
        TextView tv = text(ctx, label, 12.5f, checked ? Color.WHITE : bodyColor(), checked);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(checked ? palette.primary : palette.primarySoft);
        bg.setCornerRadius(dp(ctx, 999));
        bg.setStroke(dp(ctx, 1), checked ? palette.primary : palette.line);
        tv.setBackground(bg);
        int padH = dp(ctx, 12);
        tv.setPadding(padH, dp(ctx, 6), padH, dp(ctx, 6));
        tv.setTag(Boolean.valueOf(checked));
        return tv;
    }

    public static void setChip(TextView chip, boolean checked) {
        chip.setTag(Boolean.valueOf(checked));
        chip.setTextColor(checked ? Color.WHITE : bodyColor());
        chip.setTypeface(checked ? Typeface.DEFAULT_BOLD : Typeface.DEFAULT);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(checked ? palette.primary : palette.primarySoft);
        bg.setCornerRadius(dp(chip.getContext(), 999));
        bg.setStroke(dp(chip.getContext(), 1), checked ? palette.primary : palette.line);
        chip.setBackground(bg);
    }

    /**
     * 可折叠分区：标题行（标题 + 右侧状态 + 箭头）点一下展开/收起。
     *
     * <p>标签编辑器用它把 8 个字段和封面/歌词分区，避免一屏塞满。
     */
    public static final class Section {
        public final LinearLayout root;
        public final LinearLayout body;
        public final TextView title;
        public final TextView state;
        public final TextView arrow;
        private final View header;
        private boolean expanded;
        private Runnable onToggle;

        Section(LinearLayout root, LinearLayout body, TextView title, TextView state,
                TextView arrow, View header, boolean expanded) {
            this.root = root;
            this.body = body;
            this.title = title;
            this.state = state;
            this.arrow = arrow;
            this.header = header;
            this.expanded = expanded;
            apply();
        }

        public boolean isExpanded() {
            return expanded;
        }

        public void setExpanded(boolean value) {
            expanded = value;
            apply();
        }

        public void toggle() {
            setExpanded(!expanded);
            if (onToggle != null) {
                onToggle.run();
            }
        }

        /** 展开/收起状态变化后回调（用于把状态落盘到偏好）。 */
        public void setOnToggleListener(Runnable r) {
            this.onToggle = r;
        }

        /** 右侧小字（「3 项已改」「已有 52 行」）。 */
        public void setState(String text) {
            state.setText(text == null ? "" : text);
        }

        private void apply() {
            body.setVisibility(expanded ? View.VISIBLE : View.GONE);
            arrow.setText(expanded ? "▾" : "▸");
            header.setContentDescription(title.getText() + (expanded ? " 已展开" : " 已收起"));
        }
    }

    public static Section section(final Context ctx, String title, boolean expanded) {
        LinearLayout root = vertical(ctx);
        final LinearLayout header = horizontal(ctx);
        header.setGravity(android.view.Gravity.CENTER_VERTICAL);
        int padV = dp(ctx, 8);
        header.setPadding(0, padV, 0, padV);

        final TextView tv = text(ctx, title, 14.5f, textColor(), true);
        final TextView state = caption(ctx, "");
        final TextView arrow = text(ctx, "▾", 13, subColor(), false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        header.addView(tv, lp);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        slp.setMargins(0, 0, dp(ctx, 8), 0);
        header.addView(state, slp);
        header.addView(arrow);

        final LinearLayout body = vertical(ctx);
        root.addView(header);
        root.addView(body);

        final Section section = new Section(root, body, tv, state, arrow, header, expanded);
        header.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                section.toggle();
            }
        });
        return section;
    }

    /**
     * 可折叠卡片：与 {@link #section} 行为一致（标题行点击展开/收起 + 箭头），
     * 但整体包在 {@link #card} 的圆角背景里，适合「整理页」这类由多张独立卡片组成、卡片又偏多的页面。
     */
    public static Section collapsibleCard(final Context ctx, String title, boolean expanded) {
        LinearLayout card = card(ctx);
        final LinearLayout header = horizontal(ctx);
        header.setGravity(android.view.Gravity.CENTER_VERTICAL);
        int padV = dp(ctx, 8);
        header.setPadding(0, padV, 0, padV);

        final TextView tv = text(ctx, title, 16, textColor(), true);
        final TextView state = caption(ctx, "");
        final TextView arrow = text(ctx, "▾", 14, subColor(), false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        header.addView(tv, lp);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        slp.setMargins(0, 0, dp(ctx, 8), 0);
        header.addView(state, slp);
        header.addView(arrow);

        final LinearLayout body = vertical(ctx);
        card.addView(header);
        card.addView(body);

        final Section section = new Section(card, body, tv, state, arrow, header, expanded);
        header.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                section.toggle();
            }
        });
        return section;
    }
}
