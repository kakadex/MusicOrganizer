package com.dsh.musicorganizer.ui;

import android.content.Context;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.dsh.musicorganizer.core.Layout;

/**
 * 自动整理卡片内的内联选项（v0.1.99）：
 * 只保留「整理目录结构」的 艺人 / 专辑 两个选项，其余设置收进「设置…」按钮
 * 弹出的 {@link OrganizeSettingsDialog}。
 */
public final class OrganizeOptionsPanel extends LinearLayout {

    private final MainActivity host;

    public OrganizeOptionsPanel(MainActivity host) {
        super(host);
        this.host = host;
        setOrientation(VERTICAL);
        buildOrganizeOptions();
        divider();
        buildSettingsEntry();
    }

    private void divider() {
        View d = UiKit.divider(host);
        UiKit.margin(d, 0, 10, 0, 0);
        addView(d);
    }

    private void subTitle(String text, String caption) {
        TextView t = UiKit.text(host, text, 15, UiKit.textColor(), true);
        UiKit.margin(t, 0, 12, 0, 0);
        addView(t);
        addView(UiKit.caption(host, caption));
    }

    // ---- 整理选项：只保留 艺人 / 专辑 两个目录结构 ----
    private void buildOrganizeOptions() {
        Context ctx = host;
        subTitle("整理选项", "「自动整理」按这里选的目录结构归位，改完下一次整理即生效。");
        final int[] keepIds = new int[]{Layout.ARTIST, Layout.ARTIST_ALBUM};
        final TextView[] layoutChips = new TextView[keepIds.length];
        LinearLayout layoutRow = UiKit.horizontal(ctx);
        layoutRow.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < keepIds.length; i++) {
            final int id = keepIds[i];
            final TextView chip = UiKit.chip(ctx, Layout.LABELS[id],
                    host.repo.intVal("layout_id", Layout.ARTIST) == id);
            layoutChips[i] = chip;
            chip.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    host.repo.setInt("layout_id", id);
                    for (int k = 0; k < layoutChips.length; k++) {
                        UiKit.setChip(layoutChips[k], keepIds[k] == id);
                    }
                    host.log("整理目录结构：" + Layout.label(id) + "（" + Layout.HINTS[id] + "）", "info");
                }
            });
            LinearLayout.LayoutParams chp = new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            if (i > 0) {
                chp.setMargins(UiKit.dp(ctx, 6), 0, 0, 0);
            }
            layoutRow.addView(chip, chp);
        }
        UiKit.margin(layoutRow, 0, 6, 0, 6);
        addView(layoutRow);
        addView(UiKit.caption(ctx, "艺人：" + Layout.HINTS[Layout.ARTIST] + "　专辑："
                + Layout.HINTS[Layout.ARTIST_ALBUM]));
    }

    // ---- 设置入口：一个按钮，点进去设置写入策略 / 权重 / 字段策略 / 数据源 ----
    private void buildSettingsEntry() {
        Context ctx = host;
        subTitle("设置", "批量写入策略、在线匹配权重、字段写入策略、数据源，点进去设置。");
        Button btnSettings = UiKit.button(ctx, "设置写入策略与数据源…", false);
        btnSettings.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                OrganizeSettingsDialog.show(host);
            }
        });
        addView(btnSettings);
    }
}
