package com.dsh.musicorganizer.ui;

import com.dsh.musicorganizer.core.TagBatch;
import com.dsh.musicorganizer.core.TextUtil;

import java.util.ArrayList;
import java.util.List;

/**
 * 批量标签预览确认 —— 联网拿到的标签**不直接写入**，
 * 先在这里逐条列出「文件名 → 匹配结果 · 将改哪些字段」，勾选后才真正写盘。
 *
 * <p>面板本体是 {@link PreviewSheet}（全屏、全选/全不选/反选、行内「明细」看逐字段旧→新）。
 */
public final class TagPreview {

    private TagPreview() {
    }

    public interface OnConfirm {
        void confirmed(List<TagBatch.Match> selected);
    }

    public static void showBatch(final MainActivity host, final List<TagBatch.Match> matches,
                                 final String policySummary, final OnConfirm onConfirm) {
        String hint = "匹配 " + matches.size() + " 首（" + policySummary + "）\n"
                + "勾选要写入的条目，没勾的不会写；点行内「明细」看逐字段的旧值 → 新值。";
        showInternal(host, matches, hint, "写入选中", "取消", onConfirm);
    }

    /**
     * 暂停时的「已获取部分」预览：先看已经匹配到的标签，不想等就直接写入这些。
     * 「停止并写入」由调用方负责先结束当前匹配任务。
     */
    public static void showPartial(final MainActivity host, final List<TagBatch.Match> matches,
                                   final OnConfirm onConfirm) {
        String hint = "匹配已暂停，下面是暂停前已完成的部分（共 " + matches.size()
                + " 首，按完成顺序）。\n\n"
                + "「停止并写入」会结束当前匹配，只写入选中的标签，其余不再查询；\n"
                + "「继续匹配」则回到任务继续查询。";
        showInternal(host, matches, hint, "停止并写入", "继续匹配", onConfirm);
    }

    private static void showInternal(final MainActivity host,
                                     final List<TagBatch.Match> matches,
                                     final String hint, final String okLabel,
                                     final String cancelLabel, final OnConfirm onConfirm) {
        List<PreviewSheet.Item> items = new ArrayList<PreviewSheet.Item>();
        for (final TagBatch.Match m : matches) {
            items.add(new PreviewSheet.Item() {
                @Override
                public boolean isSelected() {
                    return m.selected;
                }

                @Override
                public void setSelected(boolean v) {
                    m.selected = v;
                }

                @Override
                public String title() {
                    return m.file.name;
                }

                @Override
                public String subtitle() {
                    StringBuilder sb = new StringBuilder();
                    String artist = TextUtil.safeStr(m.matchedArtist);
                    String title = TextUtil.safeStr(m.matchedTitle);
                    sb.append("→ ");
                    if (artist.isEmpty() && title.isEmpty()) {
                        sb.append("（未识别）");
                    } else {
                        sb.append(artist);
                        if (!title.isEmpty()) {
                            sb.append(artist.isEmpty() ? "" : " - ").append(title);
                        }
                    }
                    String fields = m.fieldSummary();
                    if (!fields.isEmpty()) {
                        sb.append(" · 将改 ").append(fields);
                    }
                    sb.append(" · ").append(String.format("%.2f", m.confidence))
                            .append(" · ").append(TextUtil.safeStr(m.source));
                    return sb.toString();
                }

                @Override
                public boolean warn() {
                    return m.lowConfidence();
                }

                @Override
                public String detail() {
                    StringBuilder sb = new StringBuilder();
                    sb.append("匹配：").append(TextUtil.safeStr(m.matchedArtist));
                    if (!TextUtil.safeStr(m.matchedTitle).isEmpty()) {
                        sb.append(" - ").append(m.matchedTitle);
                    }
                    sb.append("　［").append(String.format("%.2f", m.confidence))
                            .append(" · ").append(TextUtil.safeStr(m.source)).append("］");
                    if (m.lowConfidence()) {
                        sb.append(" ⚠低置信");
                    }
                    sb.append('\n');
                    sb.append("当前：").append(m.beforeSummary()).append('\n');
                    sb.append("将改：").append(m.detail()).append('\n');
                    return sb.toString();
                }
            });
        }
        PreviewSheet.show(host, "标签匹配结果（预览）", hint, items, okLabel, cancelLabel,
                new PreviewSheet.Callback() {
                    @Override
                    public void onConfirm() {
                        List<TagBatch.Match> selected = new ArrayList<TagBatch.Match>();
                        for (TagBatch.Match m : matches) {
                            if (m.selected) {
                                selected.add(m);
                            }
                        }
                        onConfirm.confirmed(selected);
                    }
                });
    }
}
