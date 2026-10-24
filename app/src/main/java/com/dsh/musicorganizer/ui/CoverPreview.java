package com.dsh.musicorganizer.ui;

import com.dsh.musicorganizer.core.CoverBatch;
import com.dsh.musicorganizer.core.TextUtil;

import java.util.ArrayList;
import java.util.List;

/**
 * 封面预览：逐首列出「文件名 → 专辑（来源）」，勾选后才下载写入。
 *
 * <p>为什么必须预览：封面是**替换不可逆**的（不像文本字段能整批撤销），
 * 而专辑图配错比没有封面更难看。所以这里不做「自动写入」，也不放进撤销链路
 * （{@code TagTransaction} 的 journal 只记文本字段）。
 *
 * <p>面板走 {@link PreviewSheet}（全选/全不选/反选）。
 */
public final class CoverPreview {

    private CoverPreview() {
    }

    public interface OnConfirm {
        void confirmed(List<CoverBatch.Match> selected);
    }

    public static void showBatch(final MainActivity host, final List<CoverBatch.Match> matches,
                                 final OnConfirm onConfirm) {
        int low = 0;
        for (CoverBatch.Match m : matches) {
            if (m.confidence < 0.50) {
                low++;
            }
        }
        String hint = "共 " + matches.size() + " 首可补封面"
                + (low > 0 ? "（其中 " + low + " 首置信度偏低，已标 ⚠）" : "")
                + "。\n封面会替换文件里原有的图，写入后无法整批撤销；勾选要写入的，确认无误再继续。";

        List<PreviewSheet.Item> items = new ArrayList<PreviewSheet.Item>();
        for (final CoverBatch.Match m : matches) {
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
                    StringBuilder sb = new StringBuilder("→ ");
                    String album = TextUtil.safeStr(m.album);
                    sb.append(album.isEmpty() ? "（未知专辑）" : album);
                    String artist = TextUtil.safeStr(m.artist);
                    if (!artist.isEmpty()) {
                        sb.append(" · ").append(artist);
                    }
                    sb.append(" · 来自 ").append(CoverBatch.sourceLabel(m.source));
                    sb.append(" · ").append(String.format("%.2f", m.confidence));
                    if (m.note != null && !m.note.isEmpty()) {
                        sb.append("（").append(m.note).append("）");
                    }
                    return sb.toString();
                }

                @Override
                public boolean warn() {
                    return m.confidence < 0.50;
                }

                @Override
                public String detail() {
                    // 封面没有可预览的正文（图片本身需下载），列元信息意义不大
                    return "";
                }
            });
        }
        PreviewSheet.show(host, "封面匹配结果（预览）", hint, items, "写入选中", "取消",
                new PreviewSheet.Callback() {
                    @Override
                    public void onConfirm() {
                        List<CoverBatch.Match> selected = new ArrayList<CoverBatch.Match>();
                        for (CoverBatch.Match m : matches) {
                            if (m.selected) {
                                selected.add(m);
                            }
                        }
                        onConfirm.confirmed(selected);
                    }
                });
    }
}
