package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.app.Dialog;
import android.content.Context;
import android.content.DialogInterface;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.dsh.musicorganizer.core.Lyrics;
import com.dsh.musicorganizer.core.LyricsShift;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;

/**
 * 批量歌词时间轴偏移（v0.1.34）。
 *
 * <p>歌词来自别的版本、录音比歌词早 —— 手机上以前改不了。这里对选中的每一首：
 * 有同名 {@code .lrc} 就改 {@code .lrc}（覆盖前留 {@code .lrc.bak}），
 * 有内嵌歌词就一起改（走 {@code TagTransaction}，失败原文件不动）。
 *
 * <p>只动数字时间戳，`[ar:...]` 这类元信息原样保留；偏移后为负的钳到 0。
 */
public final class LyricsShiftDialog {

    private LyricsShiftDialog() {
    }

    /** 快捷偏移档位（毫秒）。 */
    private static final int[] PRESETS = new int[]{-1000, -500, -100, 100, 500, 1000};

    public static void show(final MainActivity host, final List<VFile> all) {
        final List<VFile> files = new ArrayList<VFile>();
        for (VFile f : all) {
            if (f.audio()) {
                files.add(f);
            }
        }
        if (files.isEmpty()) {
            host.toast("选中里没有音频文件");
            return;
        }

        final Context ctx = host;
        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout root = UiKit.vertical(ctx);
        root.setBackgroundColor(UiKit.bgColor());
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);

        root.addView(UiKit.text(ctx, "歌词时间轴偏移", 18, UiKit.textColor(), true));
        TextView hint = UiKit.caption(ctx,
                "对选中的 " + files.size() + " 首：有同名 .lrc 就改 .lrc（覆盖前留 .lrc.bak），"
                        + "有内嵌歌词一起改。正数 = 歌词整体往后推，负数 = 提前。");
        hint.setLineSpacing(UiKit.dp(ctx, 2), 1f);
        UiKit.margin(hint, 0, 6, 0, 8);
        root.addView(hint);

        final EditText input = UiKit.input(ctx, "偏移毫秒，例如 500 或 -300");
        input.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_SIGNED);
        input.setText("0");
        root.addView(input);

        LinearLayout chipRow = UiKit.horizontal(ctx);
        chipRow.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < PRESETS.length; i++) {
            final int delta = PRESETS[i];
            TextView chip = UiKit.chip(ctx, (delta > 0 ? "+" : "") + delta + "ms", false);
            UiKit.margin(chip, 0, 6, 6, 0);
            chip.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    input.setText(String.valueOf(delta));
                    input.setSelection(input.getText().length());
                }
            });
            chipRow.addView(chip);
        }
        root.addView(chipRow);

        final TextView preview = UiKit.caption(ctx, "");
        preview.setLineSpacing(UiKit.dp(ctx, 2), 1f);
        UiKit.margin(preview, 0, 10, 0, 8);
        root.addView(preview);

        Button go = UiKit.button(ctx, "应用偏移", true);
        Button cancel = UiKit.button(ctx, "取消", false);
        UiKit.margin(go, 0, 8, 0, 0);
        UiKit.margin(cancel, 0, 8, 0, 0);
        root.addView(go);
        root.addView(cancel);

        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        }
        dialog.show();

        // 预览第一首：后台读，别卡住弹窗
        new Thread(new Runnable() {
            @Override
            public void run() {
                final String text = previewOf(host, files.get(0));
                host.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        preview.setText(text);
                    }
                });
            }
        }).start();

        go.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                long delta;
                try {
                    delta = Long.parseLong(input.getText().toString().trim());
                } catch (Exception e) {
                    host.toast("偏移量要是整数毫秒");
                    return;
                }
                if (delta == 0) {
                    host.toast("偏移量是 0，什么都不用改");
                    return;
                }
                final long d = delta;
                new UiKit.Builder(ctx)
                        .setTitle("确认偏移")
                        .setMessage("把 " + files.size() + " 首的歌词整体"
                                + (d > 0 ? "往后推 " : "提前 ") + Math.abs(d) + " 毫秒。\n\n"
                                + "没有歌词的文件会被跳过；.lrc 覆盖前会留 .lrc.bak。")
                        .setNegativeButton("取消", null)
                        .setPositiveButton("开始", new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface dlg, int which) {
                                dialog.dismiss();
                                run(host, files, d);
                            }
                        })
                        .show();
            }
        });
        cancel.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
            }
        });
    }

    /** 「前 3 行 + 时间戳数量」的预览文本。 */
    private static String previewOf(MainActivity host, VFile file) {
        try {
            Storage st = host.safeStorage();
            String content = "";
            VFile lrc = Lyrics.findLrc(st, file);
            if (lrc != null) {
                content = Lyrics.readLrc(st, lrc);
            }
            boolean embedded = false;
            if (content.trim().isEmpty()) {
                Tags t = Scanner.readTagsCheap(st, host.getContentResolver(), file);
                content = t.get(Tags.LYRICS);
                embedded = !content.trim().isEmpty();
            }
            if (content.trim().isEmpty()) {
                return "第一首「" + file.name + "」没有歌词，会被跳过。";
            }
            StringBuilder sb = new StringBuilder();
            sb.append("第一首「").append(file.name).append("」")
                    .append(embedded ? "（内嵌）" : "（.lrc）")
                    .append(" · 时间戳 ").append(LyricsShift.count(content)).append(" 个\n");
            String[] lines = content.split("\n");
            int shown = 0;
            for (String line : lines) {
                if (line.trim().isEmpty()) {
                    continue;
                }
                sb.append(line.trim()).append('\n');
                if (++shown >= 3) {
                    break;
                }
            }
            return sb.toString().trim();
        } catch (Exception e) {
            return "预览失败：" + e.getMessage();
        }
    }

    private static void run(final MainActivity host, final List<VFile> files, final long delta) {
        host.runTask("歌词时间轴偏移", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                int changed = 0;
                int skipped = 0;
                int failed = 0;
                List<String> errors = new ArrayList<String>();
                for (VFile f : files) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    boolean did = false;
                    try {
                        VFile lrc = Lyrics.findLrc(st, f);
                        if (lrc != null) {
                            String content = Lyrics.readLrc(st, lrc);
                            if (LyricsShift.count(content) > 0) {
                                String err = Lyrics.writeLrc(st, f,
                                        LyricsShift.shift(content, delta), true, host);
                                if (err.isEmpty()) {
                                    did = true;
                                } else {
                                    failed++;
                                    errors.add(f.name + "（.lrc）：" + err);
                                }
                            }
                        }
                        Tags t = Scanner.readTagsCheap(st, host.getContentResolver(), f);
                        String embedded = t.get(Tags.LYRICS);
                        if (LyricsShift.count(embedded) > 0) {
                            String err = Lyrics.embedLyrics(st, host.getContentResolver(), host,
                                    f, LyricsShift.shift(embedded, delta), host);
                            if (err.isEmpty()) {
                                did = true;
                            } else if (!did) {
                                failed++;
                                errors.add(f.name + "（内嵌）：" + err);
                            }
                        }
                    } catch (Exception e) {
                        failed++;
                        errors.add(f.name + "：" + e.getMessage());
                        continue;
                    }
                    if (did) {
                        changed++;
                    } else {
                        skipped++;
                    }
                }
                return new Object[]{Integer.valueOf(changed), Integer.valueOf(skipped),
                        Integer.valueOf(failed), errors};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                Object[] r = (Object[]) result;
                int changed = ((Integer) r[0]).intValue();
                int skipped = ((Integer) r[1]).intValue();
                int failed = ((Integer) r[2]).intValue();
                @SuppressWarnings("unchecked")
                List<String> errors = (List<String>) r[3];
                host.log("歌词偏移 " + (delta > 0 ? "+" : "") + delta + "ms：改了 " + changed
                        + " 首，跳过 " + skipped + " 首，失败 " + failed + " 首",
                        failed > 0 ? "warning" : "success");
                for (int i = 0; i < Math.min(errors.size(), 5); i++) {
                    host.log("偏移失败：" + errors.get(i), "error");
                }
                host.toast("已偏移 " + changed + " 首"
                        + (skipped > 0 ? "，跳过 " + skipped : "")
                        + (failed > 0 ? "，失败 " + failed : ""));
                host.invalidateScan();
            }
        });
    }
}
