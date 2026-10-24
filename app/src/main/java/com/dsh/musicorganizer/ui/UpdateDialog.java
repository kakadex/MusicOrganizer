package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.net.Uri;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.AppUpdate;
import com.dsh.musicorganizer.net.Endpoints;
import com.dsh.musicorganizer.net.UpdateClient;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;

/**
 * 检查更新 / 下载新版本（国内优先查 Gitee，GitHub 兜底）。
 *
 * <p>流程刻意做得「不打扰」：
 * <ol>
 *   <li>点「检查更新」先弹一个可随时关掉的小窗，请求在后台线程跑（GitHub 在境内有时很慢）；</li>
 *   <li>查完再把结果换成正式内容，版本对比按 {@link AppUpdate#compare} 逐段数字比；</li>
 *   <li>下载走系统浏览器（APK 直链由发布页提供），装 APK 的权限弹窗交给系统，
 *       本应用不去申请「安装未知应用」——申请了也没用，反而多一个权限。</li>
 * </ol>
 */
public final class UpdateDialog {

    private UpdateDialog() {
    }

    /** 单线程后台池：检查更新很轻，但绝不能占任务中心（那会让底部面板和通知闪一下）。 */
    private static final ExecutorService POOL =
            Executors.newSingleThreadExecutor(new ThreadFactory() {
                @Override
                public Thread newThread(Runnable r) {
                    Thread t = new Thread(r, "update-check");
                    t.setDaemon(true);
                    return t;
                }
            });

    /** 边查边显示的等待窗（结果回来后才替换成正式内容）。 */
    public static void show(final MainActivity host) {
        show(host, null);
    }

    /**
     * @param onFinish 查完（无论成败）后回调，用于刷新调用方界面上的「上次检查」文案
     */
    public static void show(final MainActivity host, final Runnable onFinish) {
        final String installed = host.versionName();
        final AlertDialog waiting = new UiKit.Builder(host)
                .setTitle("检查更新")
                .setMessage("正在查询最新版本…\n当前版本 v" + installed)
                .setNegativeButton("关闭", null)
                .create();
        try {
            waiting.show();
        } catch (Throwable ignore) {
            return;
        }
        POOL.execute(new Runnable() {
            @Override
            public void run() {
                final UpdateClient.Result result = UpdateClient.fetchLatest();
                host.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        dismissQuietly(waiting);
                        if (host.isFinishing()) {
                            return;
                        }
                        if (result.ok()) {
                            host.repo.setLong(Repo.KEY_UPDATE_LAST, System.currentTimeMillis());
                            host.repo.setStr(Repo.KEY_UPDATE_TAG, result.release.tag);
                            boolean newer = AppUpdate.isNewer(installed, result.release.version);
                            host.log("检查更新：最新版本是 " + result.release.tag
                                    + "，本机 v" + installed + (newer ? "，可以更新" : "，已是最新"),
                                    "info");
                            showResult(host, installed, result.release, newer, onFinish);
                        } else {
                            host.log("检查更新失败：" + oneLine(result.error), "warn");
                            showError(host, installed, result.error, onFinish);
                        }
                        if (onFinish != null) {
                            onFinish.run();
                        }
                    }
                });
            }
        });
    }

    // ------------------------------------------------------------------
    // 结果面板
    // ------------------------------------------------------------------

    private static void showResult(final MainActivity host, String installed,
                                   final AppUpdate.Release rel, final boolean newer,
                                   final Runnable onFinish) {
        Context ctx = host;
        int pad = UiKit.dp(ctx, 16);
        LinearLayout box = UiKit.vertical(ctx);
        box.setPadding(pad, UiKit.dp(ctx, 4), pad, UiKit.dp(ctx, 4));

        box.addView(row(ctx, "当前版本", "v" + installed + "（build " + host.versionCode() + "）",
                UiKit.subColor(), UiKit.textColor(), false));
        int color = newer ? UiKit.errColor() : UiKit.okColor();
        String mark = newer ? "← 有新版本" : "已是最新";
        box.addView(row(ctx, "最新版本", AppUpdate.display(rel.version) + "　" + mark,
                color, color, true));
        if (!rel.apkName.isEmpty()) {
            String size = AppUpdate.humanSize(rel.apkSize);
            box.addView(row(ctx, "安装包", rel.apkName + (size.isEmpty() ? "" : " · " + size),
                    UiKit.subColor(), UiKit.bodyColor(), false));
        } else if (newer) {
            box.addView(row(ctx, "安装包", "该版本没有附带 APK，请到发布页下载",
                    UiKit.subColor(), UiKit.warnColor(), false));
        }

        String notes = AppUpdate.shortNotes(rel.notes, 14);
        if (!notes.isEmpty()) {
            box.addView(UiKit.divider(ctx));
            box.addView(UiKit.text(ctx, "更新说明", 13, UiKit.textColor(), true));
            TextView body = UiKit.text(ctx, notes, 12.5f, UiKit.bodyColor(), false);
            body.setLineSpacing(UiKit.dp(ctx, 2), 1f);
            UiKit.margin(body, 0, 4, 0, 0);
            ScrollView scroll = new ScrollView(ctx);
            scroll.addView(body);
            // 说明可能十几行：给个体面的高度上限，不把弹窗撑到全屏
            scroll.setLayoutParams(new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, UiKit.dp(ctx, 190)));
            box.addView(scroll);
        }

        if (newer) {
            TextView tip = UiKit.caption(ctx,
                    "点「下载 APK」用浏览器下载，下载完点开文件安装（系统会问一次是否允许安装）。"
                            + "本机设置与目录授权不会丢。");
            UiKit.margin(tip, 0, 6, 0, 0);
            box.addView(tip);
        }
        TextView foot = UiKit.caption(ctx,
                "打不开？可在「数据源设置 → 更新源」里换成镜像地址或改用 GitHub。");
        foot.setTextColor(UiKit.subColor());
        UiKit.margin(foot, 0, 4, 0, 0);
        box.addView(foot);

        AlertDialog.Builder b = new UiKit.Builder(host)
                .setTitle(newer ? "发现新版本 " + AppUpdate.display(rel.version) : "已是最新版本")
                .setView(box)
                .setNegativeButton(newer ? "稍后" : "关闭", finishWith(onFinish));

        if (newer && rel.hasApk()) {
            b.setPositiveButton("下载 APK", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int w) {
                    open(host, rel.apkUrl);
                    if (onFinish != null) {
                        onFinish.run();
                    }
                }
            });
            b.setNeutralButton("发布页", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int w) {
                    open(host, rel.pageUrl.isEmpty() ? UpdateClient.releasesPage() : rel.pageUrl);
                    if (onFinish != null) {
                        onFinish.run();
                    }
                }
            });
        } else if (newer) {
            b.setPositiveButton("打开发布页", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int w) {
                    open(host, rel.pageUrl.isEmpty() ? UpdateClient.releasesPage() : rel.pageUrl);
                    if (onFinish != null) {
                        onFinish.run();
                    }
                }
            });
        }
        b.show();
    }

    private static void showError(final MainActivity host, String installed,
                                  String error, final Runnable onFinish) {
        int pad = UiKit.dp(host, 16);
        LinearLayout box = UiKit.vertical(host);
        box.setPadding(pad, UiKit.dp(host, 4), pad, 0);
        box.addView(UiKit.caption(host, "当前版本 v" + installed));
        TextView tv = UiKit.text(host, error == null ? "未知错误" : error, 13, UiKit.bodyColor(), false);
        tv.setLineSpacing(UiKit.dp(host, 2), 1f);
        UiKit.margin(tv, 0, 8, 0, 0);
        box.addView(tv);

        new UiKit.Builder(host)
                .setTitle("暂时查不到新版本")
                .setView(box)
                .setPositiveButton("打开发布页", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        open(host, UpdateClient.releasesPage());
                        if (onFinish != null) {
                            onFinish.run();
                        }
                    }
                })
                .setNegativeButton("关闭", finishWith(onFinish))
                .show();
    }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    /** 「标签 + 值」一行：左标签定宽，右值占满并可换行。 */
    private static LinearLayout row(Context ctx, String label, String value,
                                    int labelColor, int valueColor, boolean bold) {
        LinearLayout h = UiKit.horizontal(ctx);
        h.setGravity(Gravity.TOP);
        UiKit.margin(h, 0, 0, 0, 6);
        TextView l = UiKit.text(ctx, label, 12.5f, labelColor, false);
        l.setWidth(UiKit.dp(ctx, 64));
        TextView v = UiKit.text(ctx, value, 13, valueColor, bold);
        v.setLayoutParams(new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        h.addView(l);
        h.addView(v);
        return h;
    }

    private static DialogInterface.OnClickListener finishWith(final Runnable onFinish) {
        return new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface d, int w) {
                if (onFinish != null) {
                    onFinish.run();
                }
            }
        };
    }

    /** 用系统浏览器打开链接；没有浏览器就明确说一声，不要静默失败。 */
    public static void open(MainActivity host, String url) {
        if (url == null || url.trim().isEmpty()) {
            host.toast("没有可打开的地址");
            return;
        }
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url.trim()));
            intent.addCategory(Intent.CATEGORY_BROWSABLE);
            host.startActivity(intent);
        } catch (ActivityNotFoundException e) {
            host.toast("这台设备上没有能打开网页的应用");
        } catch (Throwable t) {
            host.toast("打开失败：" + t.getClass().getSimpleName());
        }
    }

    private static void dismissQuietly(AlertDialog d) {
        try {
            d.dismiss();
        } catch (Throwable ignore) {
        }
    }

    private static String oneLine(String s) {
        return s == null ? "" : s.replace('\n', ' ');
    }

    /** 「上次检查 3 小时前 · 最新是 v0.1.11」这类文案（整理页状态行用）。 */
    public static String lastCheckSummary(Repo repo) {
        long last = repo.longVal(Repo.KEY_UPDATE_LAST, 0L);
        if (last <= 0) {
            return "还没有检查过更新";
        }
        long delta = System.currentTimeMillis() - last;
        if (delta < 0) {
            delta = 0;
        }
        long minutes = delta / 60000L;
        String when;
        if (minutes < 1) {
            when = "刚刚";
        } else if (minutes < 60) {
            when = minutes + " 分钟前";
        } else if (minutes < 60 * 24) {
            when = (minutes / 60) + " 小时前";
        } else {
            when = (minutes / (60 * 24)) + " 天前";
        }
        String tag = repo.str(Repo.KEY_UPDATE_TAG, "");
        return tag.isEmpty()
                ? "上次检查：" + when
                : "上次检查：" + when + " · 最新是 " + AppUpdate.display(tag);
    }

    /** 该源是否被用户停用（整理页上给个提示，免得以为功能坏了）。 */
    public static boolean disabled() {
        return !Endpoints.enabled(UpdateClient.SOURCE);
    }
}
