package com.dsh.musicorganizer.ui;

import android.app.Dialog;
import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 文件夹管理：列出已授权的音乐文件夹，
 * 右上角「＋ 添加」，每个文件夹一行（图标 + 名称 + 状态 + 移除）。
 *
 * <p>MO 目前只支持一个音乐库目录，所以列表里最多一行；结构与多文件夹列表一致，
 * 以后要扩多目录不必重做界面。
 */
public final class FolderManagerDialog {

    private FolderManagerDialog() {
    }

    public static void show(final MainActivity host) {
        final Context ctx = host;
        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);

        LinearLayout card = UiKit.vertical(ctx);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(UiKit.cardColor());
        bg.setCornerRadius(UiKit.dp(ctx, 20));
        card.setBackground(bg);
        int pad = UiKit.dp(ctx, 18);
        card.setPadding(pad, UiKit.dp(ctx, 16), pad, UiKit.dp(ctx, 16));

        // 标题行：左「文件夹管理」，右「＋ 添加」
        LinearLayout head = UiKit.horizontal(ctx);
        head.setGravity(Gravity.CENTER_VERTICAL);
        head.addView(UiKit.text(ctx, "文件夹管理", 17, UiKit.textColor(), true),
                new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        TextView add = UiKit.text(ctx, "＋ 添加", 14, UiKit.primary(), true);
        int tap = UiKit.dp(ctx, 10);
        add.setPadding(tap, tap, 0, tap);
        head.addView(add);
        card.addView(head);
        card.addView(UiKit.caption(ctx, "已授权的音乐文件夹。点右上角「＋ 添加」选择目录。"));

        // 列表
        LinearLayout list = UiKit.vertical(ctx);
        UiKit.margin(list, 0, 10, 0, 0);
        final String path = host.repo.treeDisplayName();
        boolean hasFolder = host.repo.treeUri() != null;
        if (hasFolder) {
            LinearLayout row = UiKit.horizontal(ctx);
            row.setGravity(Gravity.CENTER_VERTICAL);
            GradientDrawable rowBg = new GradientDrawable();
            rowBg.setColor(UiKit.primarySoft());
            rowBg.setCornerRadius(UiKit.dp(ctx, 14));
            row.setBackground(rowBg);
            int rp = UiKit.dp(ctx, 12);
            row.setPadding(rp, rp, rp, rp);

            row.addView(UiKit.text(ctx, "📁", 18, UiKit.primary(), false));

            LinearLayout col = UiKit.vertical(ctx);
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            clp.setMargins(UiKit.dp(ctx, 10), 0, UiKit.dp(ctx, 6), 0);
            TextView name = UiKit.text(ctx, path, 14, UiKit.textColor(), true);
            name.setSingleLine(true);
            name.setEllipsize(TextUtils.TruncateAt.MIDDLE);
            col.addView(name);
            col.addView(UiKit.caption(ctx, "当前使用中 · 音乐库"));
            row.addView(col, clp);

            TextView remove = UiKit.text(ctx, "✕", 15, UiKit.errColor(), true);
            remove.setPadding(tap, tap, 0, tap);
            remove.setContentDescription("移除文件夹");
            remove.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    confirmRemove(host, dialog, path);
                }
            });
            row.addView(remove);

            list.addView(row);
        } else {
            list.addView(UiKit.caption(ctx, "还没有添加文件夹。"));
        }
        card.addView(list);

        add.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
                host.pickFolder();
            }
        });

        // 卡片外层留白，弹窗像一张浮起的卡片
        FrameLayout shell = new FrameLayout(ctx);
        int m = UiKit.dp(ctx, 20);
        shell.setPadding(m, m, m, m);
        shell.addView(card, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        dialog.setContentView(shell);

        Window w = dialog.getWindow();
        if (w != null) {
            w.setBackgroundDrawableResource(android.R.color.transparent);
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT);
        }
        dialog.show();
    }

    private static void confirmRemove(final MainActivity host, final Dialog dialog,
                                      String path) {
        new UiKit.Builder(host)
                .setTitle("移除文件夹")
                .setMessage("将移除音乐库目录：\n" + path
                        + "\n\n只清除授权与当前列表，不会删除手机里的任何文件。")
                .setPositiveButton("移除", new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface d, int which) {
                        dialog.dismiss();
                        host.clearFolder();
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }
}
