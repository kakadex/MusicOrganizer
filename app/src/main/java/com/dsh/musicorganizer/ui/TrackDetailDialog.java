package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.text.format.DateFormat;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.dsh.musicorganizer.core.SearchIndex;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.TrackInfo;
import com.dsh.musicorganizer.core.VFile;

/**
 * 单曲详情（v0.1.51）：点曲库列表的一行打开。
 *
 * <p>分三块：文件信息（路径 / 格式 / 大小 / 时长 / 质量）、全部标签字段
 * （空的明确写「（空）」，不留白让人以为没读到）、封面与歌词的有无。
 * 底部一个「编辑标签…」直接进 {@link TagEditorDialog} —— 也就是「可以单独修改」。
 *
 * <p>单文件的操作菜单（手动归类 / 获取歌词 / 查看信息）在列表行尾的 ⋮ 按钮上，
 * 两者分工：点行看详情，点 ⋮ 做动作。
 */
public final class TrackDetailDialog {

    private TrackDetailDialog() {
    }

    public static void show(final MainActivity host, final SearchIndex.Entry e) {
        if (host == null || e == null || e.file == null) {
            return;
        }
        final VFile f = e.file;
        Context ctx = host;
        LinearLayout root = UiKit.vertical(ctx);
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);

        root.addView(UiKit.text(ctx, "文件", 13, UiKit.primary(), true));
        row(ctx, root, "文件名", f.name);
        row(ctx, root, "路径", f.pathAfterRoot());
        row(ctx, root, "格式", f.ext().isEmpty() ? "未知" : f.ext().substring(1));
        row(ctx, root, "大小", TextUtil.formatSize(f.size));
        // 时长 / 质量：列表是「滚到哪读到哪」，刚扫描完就点开某一首时它可能还没轮到，
        // 这时显示「读取中…」并在后台补读（见下面的 fillAudioInfo），不要写成「（空）」——
        // 那会让用户以为文件真的没有时长。
        boolean unknownAudio = e.durationMs <= 0 || e.bitrateKbps <= 0;
        final TextView durationValue = row(ctx, root, "时长",
                unknownAudio ? "读取中…" : TrackInfo.duration(e.durationMs));
        final TextView bitrateValue = row(ctx, root, "质量",
                unknownAudio ? "读取中…" : TrackInfo.bitrate(e.bitrateKbps));
        row(ctx, root, "修改时间", DateFormat.format("yyyy-MM-dd HH:mm",
                f.lastModified).toString());

        root.addView(UiKit.text(ctx, "标签", 13, UiKit.primary(), true));
        for (String key : Tags.KEYS) {
            String label = Tags.LABELS.containsKey(key) ? Tags.LABELS.get(key) : key;
            row(ctx, root, label, tagOf(e, key));
        }
        row(ctx, root, "封面", e.hasCover ? "有" : "无");
        row(ctx, root, "歌词", e.hasLyrics ? "有" : "无");
        if (e.hasLyrics && !e.lyrics.isEmpty()) {
            String first = e.lyrics;
            int nl = first.indexOf('\n');
            if (nl >= 0) {
                first = first.substring(0, nl);
            }
            row(ctx, root, "首行", first);
        }

        AlertDialog dialog = new UiKit.Builder(ctx)
                .setTitle(f.name)
                .setView(root)
                .setNegativeButton("关闭", null)
                .setPositiveButton("编辑标签…", new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface d, int which) {
                        TagEditorDialog.show(host, f);
                    }
                })
                .create();
        dialog.show();
        // 对话框的底色 / 标题 / 按钮是系统按主题画的，正文是我们按主题取色的，
        // 两边各画各的就会出现「白底浅字」；这里统一刷成主题卡片色。
        UiKit.tintDialog(dialog);
        if (unknownAudio) {
            fillAudioInfo(host, e, f, durationValue, bitrateValue);
        }
    }

    /**
     * 后台补读时长 / 质量，读到就回填到两行文字上（不重建对话框，免得界面闪一下）。
     *
     * <p>读到的值同时写回 {@code Entry} 与文件缓存，列表行下次重绘也能直接用。
     */
    private static void fillAudioInfo(final MainActivity host, final SearchIndex.Entry e,
                                      final VFile f, final TextView durationValue,
                                      final TextView bitrateValue) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                long[] info;
                try {
                    info = AudioInfo.read(host.getContentResolver(), host.safeStorage(), f);
                } catch (Throwable t) {
                    info = AudioInfo.ZERO;
                }
                final long ms = info[0];
                final int kbps = (int) info[1];
                if (ms <= 0 && kbps <= 0) {
                    host.runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            // 确实读不出来（少数容器 / 文件损坏）：写「未知」而不是一直「读取中…」
                            durationValue.setText("未知");
                            bitrateValue.setText("未知");
                        }
                    });
                    return;
                }
                e.durationMs = ms;
                e.bitrateKbps = kbps;
                if (f.metaCached()) {
                    f.cachedDurationMs = ms;
                    f.cachedBitrateKbps = kbps;
                }
                host.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        durationValue.setText(ms > 0 ? TrackInfo.duration(ms) : "未知");
                        bitrateValue.setText(kbps > 0 ? TrackInfo.bitrate(kbps) : "未知");
                    }
                });
            }
        }, "track-detail-audio").start();
    }

    /**
     * 取 Entry 上的标签值。
     *
     * <p>{@code Entry} 是平铺字段（title / artist / …），没有 map 可查，
     * 所以这里按 key 逐个对应。KEYS 里没有的键返回空串，调用方会显示「（空）」。
     */
    private static String tagOf(SearchIndex.Entry e, String key) {
        if ("title".equals(key)) {
            return e.title;
        }
        if ("artist".equals(key)) {
            return e.artist;
        }
        if ("album".equals(key)) {
            return e.album;
        }
        if ("genre".equals(key)) {
            return e.genre;
        }
        if ("comment".equals(key)) {
            return e.comment;
        }
        if ("year".equals(key)) {
            return e.year;
        }
        return "";
    }

    /**
     * 一行「标签名：值」；值为空写「（空）」，避免留白让人以为没读到。
     *
     * @return 值那个 {@code TextView}（详情页要异步回填时长/质量，需要拿到句柄改文字）
     */
    private static TextView row(Context ctx, LinearLayout root, String label, String value) {
        LinearLayout line = UiKit.horizontal(ctx);
        line.setGravity(android.view.Gravity.TOP);
        TextView k = UiKit.text(ctx, label, 13, UiKit.subColor(), false);
        k.setMinWidth(UiKit.dp(ctx, 60));
        line.addView(k);
        TextView v = UiKit.text(ctx, value == null || value.isEmpty() ? "（空）" : value,
                13, UiKit.textColor(), false);
        line.addView(v, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        root.addView(line);
        return v;
    }
}
