package com.dsh.musicorganizer.ui;

import android.content.Context;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;

import com.dsh.musicorganizer.core.Layout;
import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.core.TagFill;

import java.util.Map;

/**
 * 整理工具的全部选项（v0.1.73 从设置页移入「整理工具」页）：
 * 整理选项 / 批量写入策略 / 在线匹配权重 / 字段写入策略 / 数据源。
 *
 * <p>放在 {@link OrganizePage} 的可折叠卡片里，是内联小标题而不是独立卡片，
 * 避免「卡中卡」的观感。
 */
public final class OrganizeOptionsPanel extends LinearLayout {

    private final MainActivity host;
    private TextView policySummary;

    public OrganizeOptionsPanel(MainActivity host) {
        super(host);
        this.host = host;
        setOrientation(VERTICAL);
        buildOrganizeOptions();
        divider();
        buildWriteStrategy();
        divider();
        buildMatchWeight();
        divider();
        buildFieldPolicy();
        divider();
        buildDataSource();
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

    // ---- 整理选项 ----
    private void buildOrganizeOptions() {
        Context ctx = host;
        subTitle("整理选项", "「整理」页的自动整理按这里的选项执行，改完下一次整理即生效。");
        final TextView[] layoutChips = new TextView[Layout.LABELS.length];
        LinearLayout layoutRow = UiKit.horizontal(ctx);
        layoutRow.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < Layout.LABELS.length; i++) {
            final int id = i;
            final TextView chip = UiKit.chip(ctx, Layout.LABELS[i],
                    host.repo.intVal("layout_id", Layout.ARTIST) == id);
            layoutChips[i] = chip;
            chip.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    host.repo.setInt("layout_id", id);
                    for (int k = 0; k < layoutChips.length; k++) {
                        UiKit.setChip(layoutChips[k], k == id);
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
        addView(UiKit.caption(ctx, "目录结构：" + Layout.HINTS[0] + " / "
                + Layout.HINTS[1] + " / " + Layout.HINTS[3]));

        addView(bindCheck("包含子文件夹（递归）", "recursive", true));
        addView(bindCheck("跳过已归位的歌手目录", "skip_artist", true));
        addView(bindCheck("快速模式（文件名有分隔符时跳过联网校验）", "fast", true));
        addView(bindCheck("联网校验（MusicBrainz）", "net", true));
        addView(bindCheck("启用国内召回源（网易/QQ/酷狗/酷我/咪咕）", "cn", true));
        addView(bindCheck("仅预览，不移动文件（试运行）", "dry", false));
        addView(bindCheck("未识别的也移入「未识别」目录（默认关，建议先预览）", "move_unrec", false));
    }

    // ---- 批量写入策略 ----
    private void buildWriteStrategy() {
        Context ctx = host;
        subTitle("批量写入策略", "「批量获取标签 / 批量补封面 / 批量获取歌词」按这里的规则写入。");
        addView(bindCheck("覆盖已有标签（默认只补空缺字段）", "tag_overwrite", false));
        addView(bindCheck("覆盖已有封面（默认只补没有封面的）", "cover_overwrite", false));
        addView(bindCheck("覆盖已有 .lrc（先备份 .lrc.bak）", "lrc_overwrite", false));
        addView(bindCheck("接受无时间轴的纯文本歌词", "lrc_plain", false));
        addView(bindCheck("同时嵌入音频标签（MP3 / FLAC / M4A）", "lrc_embed", true));
        addView(bindCheck("歌词转简体（繁体 → 简体）", "lyrics_simplify", true,
                new Runnable() {
                    @Override
                    public void run() {
                        com.dsh.musicorganizer.core.Lyrics.setSimplify(
                                host.repo.bool("lyrics_simplify", true));
                    }
                }));
        addView(UiKit.caption(ctx,
                "港台源的歌词常是繁体，开启后写到 .lrc 与标签里的都是简体；"
                        + "日文歌词（含假名）会自动跳过，不会被误转。"));
    }

    // ---- 在线匹配：文件名权重 ----
    private void buildMatchWeight() {
        Context ctx = host;
        subTitle("在线匹配：文件名权重", "联网查标签 / 歌词时，文件名解析结果与已有标签谁更可信。");
        final TextView lblWeight = UiKit.text(ctx, weightLabel(host.repo.intVal(
                "fn_weight", NameWeight.DEFAULT_PERCENT)), 15, UiKit.primary(), true);
        UiKit.margin(lblWeight, 0, 8, 0, 0);
        addView(lblWeight);
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
        addView(sbWeight);
        addView(UiKit.caption(ctx,
                "左端 0%：只信已有标签（文件名兜底）　右端 100%：只信文件名（标签兜底）"));

        CheckBox cbIncremental = UiKit.checkbox(ctx, "增量模式：跳过上批已确认无结果的歌",
                host.repo.bool("incremental", true));
        UiKit.margin(cbIncremental, 0, 8, 0, 0);
        cbIncremental.setOnCheckedChangeListener(
                new android.widget.CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(android.widget.CompoundButton b, boolean checked) {
                        host.repo.setBool("incremental", checked);
                        host.log("增量模式：" + (checked ? "开" : "关"), "info");
                    }
                });
        addView(cbIncremental);
        addView(UiKit.caption(ctx,
                "记住每首歌上次的查询结果：库里没有的、已被质量校验拦下的、已写好的，下一批直接跳过。"
                        + "文件被替换后会重新查。"));

        CheckBox cbIgnoreMemory = UiKit.checkbox(ctx,
                "忽略匹配记忆：这一轮全部重新联网查询", host.repo.bool("ignore_memory", false));
        UiKit.margin(cbIgnoreMemory, 0, 8, 0, 0);
        cbIgnoreMemory.setOnCheckedChangeListener(
                new android.widget.CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(android.widget.CompoundButton b, boolean checked) {
                        host.repo.setBool("ignore_memory", checked);
                        host.log("忽略匹配记忆：" + (checked ? "开（下次批量全部重查）" : "关"), "info");
                    }
                });
        addView(cbIgnoreMemory);
        addView(UiKit.caption(ctx,
                "开一次跑完记得关掉：只跳过「已有结论」这一步，查询结果本身仍会照常记下来。"));
    }

    // ---- 字段写入策略 ----
    private void buildFieldPolicy() {
        Context ctx = host;
        subTitle("字段写入策略",
                "每个字段单独设「不写 / 只补空 / 覆盖」；未单独设置的字段跟随「覆盖已有标签」开关。");
        Button btnPolicy = UiKit.button(ctx, "设置字段写入策略", false);
        btnPolicy.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                FieldPolicyDialog.show(host, resolvedFieldModes(),
                        new FieldPolicyDialog.OnChanged() {
                            @Override
                            public void changed() {
                                refreshPolicySummary();
                            }
                        });
            }
        });
        addView(btnPolicy);
        policySummary = UiKit.caption(ctx, policySummaryText());
        addView(policySummary);
    }

    // ---- 数据源 ----
    private void buildDataSource() {
        Context ctx = host;
        subTitle("数据源", "标签 8 家、歌词 4 家的接口地址都可改，某家失效 / 被墙时自己换地址或关掉。");
        Button btnSources = UiKit.button(ctx, "数据源设置（接口地址 / 启用开关）", false);
        btnSources.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                DataSourceDialog.show(host);
            }
        });
        addView(btnSources);
    }

    // ------------------------------------------------------------------

    private static String weightLabel(int percent) {
        String hint = percent >= 50 ? "以文件名为准" : "以已有标签为准";
        return "文件名权重 " + percent + "% · " + hint;
    }

    private CheckBox bindCheck(String label, final String key, boolean def) {
        return bindCheck(label, key, def, null);
    }

    private CheckBox bindCheck(String label, final String key, boolean def,
                               final Runnable extra) {
        final CheckBox cb = UiKit.checkbox(host, label, host.repo.bool(key, def));
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

    private String policySummaryText() {
        Map<String, Integer> custom = host.repo.tagFieldModes();
        if (custom.isEmpty()) {
            return "跟随全局开关：" + (host.repo.bool("tag_overwrite", false) ? "全部覆盖" : "全部只补空");
        }
        StringBuilder sb = new StringBuilder("自定义：");
        Map<String, Integer> resolved = resolvedFieldModes();
        for (String f : TagFill.CANDIDATE_FIELDS) {
            if (sb.length() > 4) {
                sb.append('、');
            }
            sb.append(TagFill.label(f)).append('·')
                    .append(TagFill.modeName(TagFill.modeOf(resolved, f)));
        }
        return sb.toString();
    }

    private Map<String, Integer> resolvedFieldModes() {
        Map<String, Integer> m = TagFill.defaultModes(host.repo.bool("tag_overwrite", false));
        m.putAll(host.repo.tagFieldModes());
        return m;
    }

    private void refreshPolicySummary() {
        if (policySummary != null) {
            policySummary.setText(policySummaryText());
        }
    }
}
