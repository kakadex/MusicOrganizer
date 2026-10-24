package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.DialogInterface;

import com.dsh.musicorganizer.core.Lyrics;
import com.dsh.musicorganizer.core.TextUtil;

import java.util.ArrayList;
import java.util.List;

/**
 * 歌词预览确认 —— 获取到的歌词**不直接写入**，先在这里列出匹配结果，
 * 由用户勾选并确认后才交给 {@link Lyrics#writeMatches}。
 *
 * <p>批量面板走 {@link PreviewSheet}（全选/全不选/反选，行内「明细」看歌词正文）。
 */
public final class LyricsPreview {

    private LyricsPreview() {
    }

    public interface OnConfirm {
        /** 已确认要写入的条目（只含勾选项）。 */
        void confirmed(List<Lyrics.Match> selected);
    }

    /** 单文件：直接展示歌词内容节选，确认后写入。 */
    public static void showSingle(final MainActivity host, final Lyrics.Match match,
                                  final OnConfirm onConfirm) {
        StringBuilder sb = new StringBuilder();
        sb.append("匹配：").append(match.artist).append(" - ").append(match.title);
        if (!TextUtil.safeStr(match.sourceLabel).isEmpty()) {
            sb.append("（来自 ").append(match.sourceLabel).append("）");
        }
        if (match.simplified) {
            sb.append("（已转简体）");
        }
        sb.append('\n');
        if (!match.note.isEmpty()) {
            sb.append("注意：").append(match.note).append('\n');
        }
        sb.append("—— 歌词预览 ——\n");
        sb.append(Lyrics.excerpt(match.content, 18));
        new UiKit.Builder(host)
                .setTitle("确认写入歌词？")
                .setMessage(sb.toString())
                .setPositiveButton("写入", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        match.selected = true;
                        List<Lyrics.Match> one = new ArrayList<Lyrics.Match>();
                        one.add(match);
                        onConfirm.confirmed(one);
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    /** 批量：多选列表，默认勾选高质量（带时间轴）的条目。 */
    public static void showBatch(final MainActivity host, final List<Lyrics.Match> matches,
                                 final OnConfirm onConfirm) {
        int timeline = 0;
        for (Lyrics.Match m : matches) {
            if (m.timeline) {
                timeline++;
            }
        }
        int plain = matches.size() - timeline;
        String hint = "匹配到 " + matches.size() + " 首歌词（带时间轴 " + timeline + " 首"
                + (plain > 0 ? "，纯文本 " + plain + " 首默认不勾" : "") + "）\n"
                + "来源：" + sourceSummary(matches) + "\n"
                + "勾选要写入的，行内「明细」可先读歌词正文再决定。";
        showInternal(host, matches, hint, "写入选中", "取消", onConfirm);
    }

    /**
     * 暂停时的「已获取部分」预览：先看已经匹配到的，不想等就直接写入这些。
     * 「停止并写入」由调用方负责先结束当前匹配任务。
     */
    public static void showPartial(final MainActivity host, final List<Lyrics.Match> matches,
                                   final OnConfirm onConfirm) {
        String hint = "匹配已暂停，下面是暂停前已完成的部分（共 " + matches.size()
                + " 首，按完成顺序）。\n\n"
                + "「停止并写入」会结束当前匹配，只写入选中的歌词，其余不再查询；\n"
                + "「继续匹配」则回到任务继续查询。";
        showInternal(host, matches, hint, "停止并写入", "继续匹配", onConfirm);
    }

    private static void showInternal(final MainActivity host,
                                     final List<Lyrics.Match> matches,
                                     final String hint, final String okLabel,
                                     final String cancelLabel, final OnConfirm onConfirm) {
        List<PreviewSheet.Item> items = new ArrayList<PreviewSheet.Item>();
        for (final Lyrics.Match m : matches) {
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
                    String artist = TextUtil.safeStr(m.artist);
                    String title = TextUtil.safeStr(m.title);
                    StringBuilder sb = new StringBuilder("→ ");
                    if (artist.isEmpty() && title.isEmpty()) {
                        sb.append("（未识别）");
                    } else {
                        sb.append(artist);
                        if (!title.isEmpty()) {
                            sb.append(artist.isEmpty() ? "" : " - ").append(title);
                        }
                    }
                    sb.append(" · ").append(m.timeline ? "带时间轴" : "纯文本")
                            .append(" · ").append(lineCount(m.content)).append(" 行");
                    if (m.translationLines > 0) {
                        sb.append(" · 含译文 ").append(m.translationLines).append(" 行");
                    }
                    if (m.simplified) {
                        sb.append(" · 已转简体");
                    }
                    if (!TextUtil.safeStr(m.sourceLabel).isEmpty()) {
                        sb.append(" · ").append(m.sourceLabel);
                    }
                    return sb.toString();
                }

                @Override
                public boolean warn() {
                    return false;
                }

                @Override
                public String detail() {
                    StringBuilder sb = new StringBuilder();
                    sb.append("匹配：").append(matchLine(m)).append('\n');
                    sb.append("来源：").append(TextUtil.safeStr(m.sourceLabel).isEmpty()
                            ? "未知" : m.sourceLabel);
                    sb.append("　形态：").append(m.timeline ? "LRC（带时间轴）" : "纯文本");
                    sb.append("　").append(lineCount(m.content)).append(" 行\n");
                    if (m.simplified) {
                        sb.append("已转简体\n");
                    }
                    if (!TextUtil.safeStr(m.note).isEmpty()) {
                        sb.append("注意：").append(m.note).append('\n');
                    }
                    sb.append("\n").append(m.content == null ? "" : m.content);
                    return sb.toString();
                }
            });
        }
        PreviewSheet.show(host, "歌词匹配结果（预览）", hint, items, okLabel, cancelLabel,
                new PreviewSheet.Callback() {
                    @Override
                    public void onConfirm() {
                        List<Lyrics.Match> selected = new ArrayList<Lyrics.Match>();
                        for (Lyrics.Match m : matches) {
                            if (m.selected) {
                                selected.add(m);
                            }
                        }
                        onConfirm.confirmed(selected);
                    }
                });
    }

    /** 来源分布，如「网易云 12 · QQ 音乐 5 · LRCLIB 3」。 */
    private static String sourceSummary(List<Lyrics.Match> matches) {
        java.util.LinkedHashMap<String, Integer> counts =
                new java.util.LinkedHashMap<String, Integer>();
        for (Lyrics.Match m : matches) {
            String key = TextUtil.safeStr(m.sourceLabel);
            if (key.isEmpty()) {
                key = "未知来源";
            }
            Integer old = counts.get(key);
            counts.put(key, old == null ? 1 : old + 1);
        }
        StringBuilder sb = new StringBuilder();
        for (java.util.Map.Entry<String, Integer> e : counts.entrySet()) {
            if (sb.length() > 0) {
                sb.append(" · ");
            }
            sb.append(e.getKey()).append(' ').append(e.getValue());
        }
        return sb.toString();
    }

    /** 歌词有效行数（跳过空行），让用户在列表里就能分辨「完整版」还是「只有两句」。 */
    private static int lineCount(String content) {
        if (content == null || content.trim().isEmpty()) {
            return 0;
        }
        int n = 0;
        for (String line : content.split("\n")) {
            if (!line.trim().isEmpty()) {
                n++;
            }
        }
        return n;
    }

    private static String matchLine(Lyrics.Match m) {
        String artist = TextUtil.safeStr(m.artist);
        String title = TextUtil.safeStr(m.title);
        if (artist.isEmpty() && title.isEmpty()) {
            return "（未识别）";
        }
        if (title.isEmpty()) {
            return artist;
        }
        return artist.isEmpty() ? title : artist + " - " + title;
    }
}
