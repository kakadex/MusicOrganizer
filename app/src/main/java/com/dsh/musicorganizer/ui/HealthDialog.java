package com.dsh.musicorganizer.ui;

import android.app.Dialog;
import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.HealthCheck;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * 曲库体检（v0.1.33）。
 *
 * <p>逐个文件读一次标签（只读文件头，走 Scanner 缓存），算「完整度」和五项缺失计数，
 * 并列出前若干条具体缺什么。以前这些信息只能靠文件页的徽标一个个翻。
 *
 * <p>走 {@code runTask}：进度可见、可暂停、可取消；扫描列表为空时直接提示先扫描。
 */
public final class HealthDialog {

    private HealthDialog() {
    }

    /** 问题清单最多列这么多条（再多也没人翻，完整数据看日志）。 */
    private static final int LIST_LIMIT = 60;

    public static void show(final MainActivity host) {
        final List<VFile> all = new ArrayList<VFile>(host.repo.lastFiles);
        int audioCount = 0;
        for (VFile f : all) {
            if (!f.dir && f.audio()) {
                audioCount++;
            }
        }
        if (audioCount == 0) {
            host.toast("还没有扫描到音频文件，先去整理页「扫描统计」");
            return;
        }

        final Context ctx = host;
        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);

        LinearLayout root = UiKit.vertical(ctx);
        root.setBackgroundColor(UiKit.bgColor());
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);
        root.addView(UiKit.text(ctx, "曲库体检", 18, UiKit.textColor(), true));

        final TextView status = UiKit.caption(ctx, "准备中…");
        UiKit.margin(status, 0, 6, 0, 6);
        root.addView(status);

        final LinearLayout body = UiKit.vertical(ctx);
        ScrollView scroll = new ScrollView(ctx);
        scroll.addView(body);
        root.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        final Button again = UiKit.button(ctx, "重新体检", false);
        Button close = UiKit.button(ctx, "关闭", false);
        UiKit.margin(again, 0, 8, 0, 0);
        UiKit.margin(close, 0, 8, 0, 0);
        root.addView(again);
        root.addView(close);

        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        }
        dialog.show();

        final Runnable job = new Runnable() {
            @Override
            public void run() {
                start(host, all, status, body, dialog);
            }
        };
        again.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                job.run();
            }
        });
        close.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
            }
        });
        job.run();
    }

    private static void start(final MainActivity host, final List<VFile> all,
                              final TextView status, final LinearLayout body,
                              final Dialog dialog) {
        body.removeAllViews();
        status.setText("正在读标签…（可暂停/取消）");
        host.runTask("曲库体检", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                Set<String> lrcBases = new HashSet<String>();
                for (VFile f : all) {
                    if (!f.dir && ".lrc".equals(f.ext())) {
                        lrcBases.add(baseName(f.name));
                    }
                }
                HealthCheck.Report report = new HealthCheck.Report();
                int done = 0;
                for (VFile f : all) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    if (f.dir || !f.audio()) {
                        continue;
                    }
                    done++;
                    HealthCheck.Item item = new HealthCheck.Item(f.name, f.ext(), f.size);
                    item.lyrics = lrcBases.contains(baseName(f.name));
                    try {
                        Tags t = Scanner.readTagsCheap(st, host.getContentResolver(), f);
                        item.title = !t.get("title").trim().isEmpty();
                        item.artist = !t.get("artist").trim().isEmpty();
                        item.album = !t.get("album").trim().isEmpty();
                        if (!item.lyrics) {
                            item.lyrics = !t.get(Tags.LYRICS).trim().isEmpty();
                        }
                        item.cover = Scanner.hasCover(st, host.getContentResolver(), f);
                    } catch (Exception e) {
                        // 读不出来的当「全都缺」，至少能被列进清单
                    }
                    report.add(item);
                }
                report.lyricFiles = lrcBases.size();
                return report;
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    status.setText("体检失败：" + error.getMessage());
                    return;
                }
                HealthCheck.Report r = (HealthCheck.Report) result;
                status.setText(r.audio == 0 ? "没有可体检的音频"
                        : "完整度 " + r.completeness() + "%（" + HealthCheck.size(r.bytes) + "）");
                render(host, body, r);
                host.log("曲库体检：" + r.headline()
                        + (r.lines().isEmpty() ? "，各字段齐全" : "，" + join(r.lines())), "info");
            }
        });
    }

    private static void render(MainActivity host, LinearLayout body, HealthCheck.Report r) {
        Context ctx = body.getContext();
        TextView head = UiKit.text(ctx, r.headline(), 22, UiKit.primary(), true);
        body.addView(head);
        TextView sub = UiKit.caption(ctx, "齐全 " + r.complete() + " 首 · 共 "
                + HealthCheck.size(r.bytes) + " · 歌词文件 " + r.lyricFiles + " 个");
        UiKit.margin(sub, 0, 4, 0, 8);
        body.addView(sub);

        if (!r.extLine().isEmpty()) {
            body.addView(UiKit.caption(ctx, "格式：" + r.extLine()));
            UiKit.margin(body.getChildAt(body.getChildCount() - 1), 0, 0, 0, 8);
        }

        LinearLayout card = UiKit.card(ctx);
        card.addView(UiKit.text(ctx, "缺失情况", 15, UiKit.textColor(), true));
        List<String> lines = r.lines();
        if (lines.isEmpty()) {
            card.addView(UiKit.caption(ctx, "五项字段全部齐全，没什么可补的。"));
        } else {
            for (String line : lines) {
                TextView t = UiKit.text(ctx, line, 14, UiKit.bodyColor(), false);
                UiKit.margin(t, 0, 4, 0, 0);
                card.addView(t);
            }
        }
        body.addView(card);

        if (r.issues.isEmpty()) {
            return;
        }
        LinearLayout list = UiKit.card(ctx);
        UiKit.margin(list, 0, 10, 0, 0);
        list.addView(UiKit.text(ctx, "问题清单（前 " + Math.min(LIST_LIMIT, r.issues.size())
                + " 条）", 15, UiKit.textColor(), true));
        int n = Math.min(LIST_LIMIT, r.issues.size());
        for (int i = 0; i < n; i++) {
            HealthCheck.Item it = r.issues.get(i);
            TextView name = UiKit.text(ctx, it.name, 13, UiKit.bodyColor(), false);
            UiKit.margin(name, 0, 6, 0, 0);
            list.addView(name);
            TextView miss = UiKit.text(ctx, "缺 " + it.missing(), 12, UiKit.warnColor(), false);
            list.addView(miss);
        }
        if (r.issues.size() > n) {
            list.addView(UiKit.caption(ctx, "还有 " + (r.issues.size() - n) + " 条未列出"));
        }
        body.addView(list);
    }

    private static String join(List<String> parts) {
        StringBuilder sb = new StringBuilder();
        for (String p : parts) {
            if (sb.length() > 0) {
                sb.append("，");
            }
            sb.append(p);
        }
        return sb.toString();
    }

    /** 去掉扩展名、统一小写，用于「音频找同名歌词」。 */
    private static String baseName(String name) {
        if (name == null) {
            return "";
        }
        int dot = name.lastIndexOf('.');
        String s = dot > 0 ? name.substring(0, dot) : name;
        return s.trim().toLowerCase(Locale.US);
    }
}
