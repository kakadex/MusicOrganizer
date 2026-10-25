package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.core.TagFill;

import java.util.Map;

/**
 * 整理设置对话框（v0.1.99）：
 * 把原来平铺在整理页的「批量写入策略 / 在线匹配权重 / 字段写入策略 / 数据源」
 * 收进一个对话框，入口是「自动整理」卡片里的「设置…」按钮。
 */
public final class OrganizeSettingsDialog {

    private OrganizeSettingsDialog() {
    }

    public static void show(final MainActivity host) {
        Context ctx = host;
        LinearLayout panel = UiKit.vertical(ctx);
        int pad = UiKit.dp(ctx, 18);
        panel.setPadding(pad, pad, pad, pad);

        // ---- 批量写入策略 ----
        addSubTitle(panel, ctx, "批量写入策略",
                "「批量获取标签 / 批量补封面 / 批量获取歌词」按这里的规则写入。");
        panel.addView(bindCheck(host, ctx, "覆盖已有标签（默认只补空缺字段）", "tag_overwrite", false));
        panel.addView(bindCheck(host, ctx, "覆盖已有封面（默认只补没有封面的）", "cover_overwrite", false));
        panel.addView(bindCheck(host, ctx, "覆盖已有 .lrc（先备份 .lrc.bak）", "lrc_overwrite", false));
        panel.addView(bindCheck(host, ctx, "接受无时间轴的纯文本歌词", "lrc_plain", false));
        panel.addView(bindCheck(host, ctx, "同时嵌入音频标签（MP3 / FLAC / M4A）", "lrc_embed", true));
        panel.addView(bindCheck(host, ctx, "歌词转简体（繁体 → 简体）", "lyrics_simplify", true,
                new Runnable() {
                    @Override
                    public void run() {
                        com.dsh.musicorganizer.core.Lyrics.setSimplify(
                                host.repo.bool("lyrics_simplify", true));
                    }
                }));
        panel.addView(UiKit.caption(ctx,
                "港台源的歌词常是繁体，开启后写到 .lrc 与标签里的都是简体；"
                        + "日文歌词（含假名）会自动跳过，不会被误转。"));
        addDivider(panel, ctx);

        // ---- 在线匹配：文件名权重 ----
        addSubTitle(panel, ctx, "在线匹配：文件名权重",
                "联网查标签 / 歌词时，文件名解析结果与已有标签谁更可信。");
        final TextView lblWeight = UiKit.text(ctx, weightLabel(host.repo.intVal(
                "fn_weight", NameWeight.DEFAULT_PERCENT)), 15, UiKit.primary(), true);
        UiKit.margin(lblWeight, 0, 8, 0, 0);
        panel.addView(lblWeight);
        SeekBar sbWeight = UiKit.slider(ctx,
                host.repo.intVal("fn_weight", NameWeight.DEFAULT_PERCENT),
                NameWeight.MAX_PERCENT);
        sbWeight.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                lblWeight.setText(weightLabel(progress));
                if (fromUser) {
                    host.repo.setInt("fn_weight", progress);
                }
            }

            @Override
            public void onStartTrackingTouch(SeekBar seekBar) {
            }

            @Override
            public void onStopTrackingTouch(SeekBar seekBar) {
            }
        });
        panel.addView(sbWeight);
        panel.addView(UiKit.caption(ctx,
                "左端 0%：只信已有标签（文件名兜底）　右端 100%：只信文件名（标签兜底）"));
        panel.addView(bindCheck(host, ctx, "增量模式：跳过上批已确认无结果的歌", "incremental", true));
        panel.addView(bindCheck(host, ctx, "忽略匹配记忆：这一轮全部重新联网查询", "ignore_memory", false));
        addDivider(panel, ctx);

        // ---- 字段写入策略 ----
        addSubTitle(panel, ctx, "字段写入策略",
                "每个字段单独设「不写 / 只补空 / 覆盖」；未单独设置的字段跟随「覆盖已有标签」开关。");
        final TextView policySummary = UiKit.caption(ctx, policySummaryText(host));
        UiKit.margin(policySummary, 0, 0, 0, 8);
        panel.addView(policySummary);
        Button btnPolicy = UiKit.button(ctx, "设置字段写入策略", false);
        btnPolicy.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                FieldPolicyDialog.show(host, resolvedFieldModes(host),
                        new FieldPolicyDialog.OnChanged() {
                            @Override
                            public void changed() {
                                policySummary.setText(policySummaryText(host));
                            }
                        });
            }
        });
        panel.addView(btnPolicy);
        addDivider(panel, ctx);

        // ---- 数据源 ----
        addSubTitle(panel, ctx, "数据源",
                "标签 8 家、歌词 4 家的接口地址都可改，某家失效 / 被墙时自己换地址或关掉。");
        Button btnSources = UiKit.button(ctx, "数据源设置（接口地址 / 启用开关）", false);
        btnSources.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                DataSourceDialog.show(host);
            }
        });
        panel.addView(btnSources);

        ScrollView scroll = new ScrollView(ctx);
        scroll.addView(panel);

        AlertDialog dialog = new UiKit.Builder(host)
                .setTitle("整理设置")
                .setView(scroll)
                .setPositiveButton("完成", null)
                .show();
        UiKit.tintDialog(dialog);
    }

    // ------------------------------------------------------------------

    private static void addSubTitle(LinearLayout panel, Context ctx, String text, String caption) {
        TextView t = UiKit.text(ctx, text, 15, UiKit.textColor(), true);
        UiKit.margin(t, 0, 12, 0, 0);
        panel.addView(t);
        panel.addView(UiKit.caption(ctx, caption));
    }

    private static void addDivider(LinearLayout panel, Context ctx) {
        View d = UiKit.divider(ctx);
        UiKit.margin(d, 0, 10, 0, 0);
        panel.addView(d);
    }

    private static String weightLabel(int percent) {
        String hint = percent >= 50 ? "以文件名为准" : "以已有标签为准";
        return "文件名权重 " + percent + "% · " + hint;
    }

    private static CheckBox bindCheck(final MainActivity host, Context ctx, String label,
                                      final String key, boolean def) {
        return bindCheck(host, ctx, label, key, def, null);
    }

    private static CheckBox bindCheck(final MainActivity host, Context ctx, String label,
                                      final String key, boolean def, final Runnable extra) {
        final CheckBox cb = UiKit.checkbox(ctx, label, host.repo.bool(key, def));
        cb.setOnCheckedChangeListener(
                new android.widget.CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(android.widget.CompoundButton b, boolean checked) {
                        host.repo.setBool(key, checked);
                        if (extra != null) {
                            extra.run();
                        }
                    }
                });
        return cb;
    }

    private static String policySummaryText(MainActivity host) {
        Map<String, Integer> custom = host.repo.tagFieldModes();
        if (custom.isEmpty()) {
            return "跟随全局开关：" + (host.repo.bool("tag_overwrite", false) ? "全部覆盖" : "全部只补空");
        }
        StringBuilder sb = new StringBuilder("自定义：");
        Map<String, Integer> resolved = resolvedFieldModes(host);
        for (String f : TagFill.CANDIDATE_FIELDS) {
            if (sb.length() > 4) {
                sb.append('、');
            }
            sb.append(TagFill.label(f)).append('·')
                    .append(TagFill.modeName(TagFill.modeOf(resolved, f)));
        }
        return sb.toString();
    }

    private static Map<String, Integer> resolvedFieldModes(MainActivity host) {
        Map<String, Integer> m = TagFill.defaultModes(host.repo.bool("tag_overwrite", false));
        m.putAll(host.repo.tagFieldModes());
        return m;
    }
}
