package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.view.View;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.dsh.musicorganizer.core.Lyrics;
import com.dsh.musicorganizer.core.LyricsTool;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;

/**
 * 歌词工具箱（v0.1.80）。
 *
 * <p>只做**本地文本处理**：删空行、去头部标签（{@code [ti:]} 这类）、去时间轴、
 * 规范时间轴、去重复行。单曲和批量共用同一个入口。
 *
 * <p>安全策略：
 * <ul>
 *   <li>只处理**已存在的同名 {@code .lrc}** —— 没有外挂歌词的文件直接跳过，
 *       不去动内嵌歌词（内嵌走标签事务，风险更高）；</li>
 *   <li>改写前由 {@link Lyrics#writeLrc} 自动把旧内容备份成 {@code .lrc.bak}；</li>
 *   <li>先跑一遍算出「会改几首」，再让用户确认。</li>
 * </ul>
 */
public final class LyricsToolDialog {

    /** 动作定义：位标记 + 名字。 */
    private static final int[] OPS = {
            LyricsTool.OP_EMPTY,
            LyricsTool.OP_HEADER,
            LyricsTool.OP_TIMESTAMP,
            LyricsTool.OP_NORMALIZE,
            LyricsTool.OP_DEDUPE,
    };

    private static final String[] LABELS = {
            "删除空行",
            "去掉头部标签（[ti:] [ar:] [offset:] 等）",
            "去掉时间轴（只留纯文本）",
            "规范时间轴（[1:2.3] → [01:02.30]）",
            "删除完全重复的行",
    };

    private LyricsToolDialog() {
    }

    /** 单曲入口。 */
    public static void show(MainActivity host, VFile file) {
        List<VFile> one = new ArrayList<VFile>();
        one.add(file);
        show(host, one);
    }

    /** 批量入口（只有一个文件时文案会自动变单曲）。 */
    public static void show(final MainActivity host, final List<VFile> files) {
        if (files == null || files.isEmpty()) {
            host.toast("先选择要处理的歌曲");
            return;
        }
        Context ctx = host;
        LinearLayout box = UiKit.vertical(ctx);
        int pad = UiKit.dp(ctx, 16);
        box.setPadding(pad, UiKit.dp(ctx, 8), pad, UiKit.dp(ctx, 8));
        box.addView(UiKit.caption(ctx,
                "只处理同名 .lrc 外挂歌词；原内容改写前会备份为 .lrc.bak。"));

        final CheckBox[] boxes = new CheckBox[OPS.length];
        for (int i = 0; i < OPS.length; i++) {
            CheckBox cb = UiKit.checkbox(ctx, LABELS[i], i < 2);
            UiKit.margin(cb, 0, 6, 0, 0);
            box.addView(cb);
            boxes[i] = cb;
        }

        new AlertDialog.Builder(ctx)
                .setTitle(files.size() == 1 ? "歌词工具箱" : "歌词工具箱（" + files.size() + " 首）")
                .setView(box)
                .setNegativeButton("取消", null)
                .setPositiveButton("开始处理", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        int ops = 0;
                        for (int i = 0; i < OPS.length; i++) {
                            if (boxes[i].isChecked()) {
                                ops |= OPS[i];
                            }
                        }
                        if (ops == 0) {
                            host.toast("至少选一项");
                            return;
                        }
                        run(host, files, ops);
                    }
                })
                .show();
    }

    private static void run(final MainActivity host, final List<VFile> files, final int ops) {
        host.runTask("整理歌词", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                int handled = 0;
                int changed = 0;
                int failed = 0;
                for (VFile f : files) {
                    if (f == null || f.dir) {
                        continue;
                    }
                    VFile lrc = Lyrics.findLrc(st, f);
                    if (lrc == null) {
                        continue;   // 没有外挂歌词，跳过（不动内嵌）
                    }
                    handled++;
                    try {
                        String old = Lyrics.readLrc(st, lrc);
                        if (old == null || old.isEmpty()) {
                            continue;
                        }
                        String now = apply(old, ops);
                        if (now.isEmpty() || now.equals(old)) {
                            continue;
                        }
                        String err = Lyrics.writeLrc(st, f, now, true, host);
                        if (err == null || err.isEmpty()) {
                            changed++;
                        } else {
                            failed++;
                        }
                    } catch (Throwable t) {
                        failed++;
                    }
                }
                return new int[]{files.size(), handled, changed, failed};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.message("整理歌词失败", TextUtil.shortError(error));
                    return;
                }
                int[] r = (int[]) result;
                StringBuilder sb = new StringBuilder();
                sb.append("选中 ").append(r[0]).append(" 首\n")
                        .append("有外挂歌词 ").append(r[1]).append(" 首\n")
                        .append("实际改写 ").append(r[2]).append(" 首");
                if (r[3] > 0) {
                    sb.append("\n失败 ").append(r[3]).append(" 首（真机上多半是目录权限）");
                }
                if (r[1] == 0) {
                    sb.append("\n\n这些歌都没有同名 .lrc 文件，所以没有可处理的内容。");
                } else if (r[2] == 0) {
                    sb.append("\n\n内容已经符合要求，没有变化。");
                } else {
                    sb.append("\n\n旧内容已备份为 .lrc.bak。");
                }
                host.message("整理歌词完成", sb.toString());
                host.log("整理歌词：" + sb.toString().replace('\n', ' '), "info");
            }
        });
    }

    /** 按勾选的动作依次处理。 */
    static String apply(String lrc, int ops) {
        String s = lrc;
        if ((ops & LyricsTool.OP_EMPTY) != 0) {
            s = LyricsTool.stripEmptyLines(s);
        }
        if ((ops & LyricsTool.OP_HEADER) != 0) {
            s = LyricsTool.stripHeaders(s);
        }
        if ((ops & LyricsTool.OP_TIMESTAMP) != 0) {
            s = LyricsTool.stripTimestamps(s);
        }
        if ((ops & LyricsTool.OP_NORMALIZE) != 0) {
            s = LyricsTool.normalizeTimestamps(s);
        }
        if ((ops & LyricsTool.OP_DEDUPE) != 0) {
            s = LyricsTool.dedupeLines(s);
        }
        return s;
    }
}
