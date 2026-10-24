package com.dsh.musicorganizer.ui;

import android.app.Dialog;
import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.VFile;

import java.util.List;

/**
 * 多选操作弹层（v0.1.56，v0.1.66 改成小底部弹层）。
 *
 * <p>形态：贴在屏幕底部、只圆上面两角、高度不超过屏幕 1/4、内容可上下滑，
 * 上方文件列表仍然可见（不是整屏遮罩）。顶部一行：左侧「已选择 N 项」，右侧「全选 / 关闭」。
 */
public final class BatchMenuDialog {

    private BatchMenuDialog() {
    }

    /** 一条操作。hint 可空（不显示副标题）。 */
    public static final class Item {
        final String label;
        final String hint;
        final Runnable action;

        public Item(String label, String hint, Runnable action) {
            this.label = label;
            this.hint = hint;
            this.action = action;
        }
    }

    /**
     * 多选弹层与库页之间的桥：弹层里的「全选」要能改库页的选择集，
     * 每个操作也要在执行时重新取「当前选中的文件」（否则点了全选后仍只对旧集合生效）。
     */
    public interface SelectionHost {
        int selectedCount();

        int totalCount();

        /** 当前选中的文件（每次点击操作时现取，保证「全选」之后是最新的）。 */
        List<VFile> selectedFiles();

        /** 全选 / 取消全选 切换。 */
        void toggleSelectAll();

        /** 退出多选模式（关闭弹层时调用）。 */
        void exitSelection();
    }

    /** 通用清单弹层（无多选头部）。 */
    public static void show(final MainActivity host, String title, final List<Item> items) {
        showSheet(host, title, items, null);
    }

    /** 流式小弹层：底部、可滑、≤1/4 屏，顶部「已选 N / 全选 / 关闭」。 */
    public static void showForSelection(final MainActivity host, final SelectionHost sel) {
        if (host == null || sel == null) {
            return;
        }
        List<Item> items = buildSelectionItems(host, sel);
        showSheet(host, null, items, sel);
    }

    private static void showSheet(final MainActivity host, String title,
                                  final List<Item> items, final SelectionHost sel) {
        final Context ctx = host;
        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);

        LinearLayout root = UiKit.vertical(ctx);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(UiKit.cardColor());
        // 只圆上面两角：贴在屏幕底部的弹层（常见的小弹层形态）
        bg.setCornerRadii(new float[]{
                UiKit.dp(ctx, 20), UiKit.dp(ctx, 20),
                UiKit.dp(ctx, 20), UiKit.dp(ctx, 20),
                0, 0, 0, 0});
        root.setBackground(bg);
        int padH = UiKit.dp(ctx, 18);
        root.setPadding(padH, UiKit.dp(ctx, 12), padH, UiKit.dp(ctx, 8));

        // 顶部小横条：提示可下拉关闭
        View grip = new View(ctx);
        GradientDrawable gripBg = new GradientDrawable();
        gripBg.setColor(UiKit.lineColor());
        gripBg.setCornerRadius(UiKit.dp(ctx, 2));
        grip.setBackground(gripBg);
        LinearLayout.LayoutParams glp = new LinearLayout.LayoutParams(
                UiKit.dp(ctx, 36), UiKit.dp(ctx, 4));
        glp.gravity = Gravity.CENTER_HORIZONTAL;
        glp.bottomMargin = UiKit.dp(ctx, 8);
        root.addView(grip, glp);

        // ---- 顶部一行：左「已选择 N 项」，右「全选 / 关闭」----
        if (sel != null) {
            final LinearLayout headRow = UiKit.horizontal(ctx);
            headRow.setGravity(Gravity.CENTER_VERTICAL);
            final TextView count = UiKit.text(ctx,
                    "已选择 " + sel.selectedCount() + " 项", 14, UiKit.primary(), true);
            headRow.addView(count, new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

            final TextView all = UiKit.text(ctx, allLabel(sel), 14, UiKit.primary(), false);
            int tap = UiKit.dp(ctx, 10);
            all.setPadding(tap, tap, tap, tap);
            final TextView finalAll = all;
            all.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    sel.toggleSelectAll();
                    count.setText("已选择 " + sel.selectedCount() + " 项");
                    finalAll.setText(allLabel(sel));
                }
            });
            headRow.addView(all);

            TextView close = UiKit.text(ctx, "关闭", 14, UiKit.subColor(), false);
            close.setPadding(tap, tap, 0, tap);
            close.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    dialog.dismiss();
                    sel.exitSelection();
                }
            });
            headRow.addView(close);
            root.addView(headRow);
        } else {
            root.addView(UiKit.text(ctx, title == null ? "操作" : title, 14,
                    UiKit.subColor(), true));
        }

        // ---- 可上下滑的动作清单（高度上限：整屏 1/4 减去头部占用）----
        LinearLayout body = UiKit.vertical(ctx);
        for (int i = 0; i < items.size(); i++) {
            final Item it = items.get(i);
            if (i > 0) {
                body.addView(UiKit.divider(ctx));
            }
            LinearLayout row = UiKit.vertical(ctx);
            int padV = UiKit.dp(ctx, 9);
            row.setPadding(0, padV, 0, padV);
            row.addView(UiKit.text(ctx, it.label, 15, UiKit.textColor(), false));
            if (it.hint != null && !it.hint.isEmpty()) {
                TextView h = UiKit.caption(ctx, it.hint);
                UiKit.margin(h, 0, 2, 0, 0);
                row.addView(h);
            }
            row.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    dialog.dismiss();
                    if (it.action != null) {
                        host.runOnUiThread(new Runnable() {
                            @Override
                            public void run() {
                                it.action.run();
                            }
                        });
                    }
                }
            });
            body.addView(row, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));
        }

        int screenH = ctx.getResources().getDisplayMetrics().heightPixels;
        int bodyCap;
        if (sel != null) {
            // 总高不超过整屏 1/4；扣掉 grip + 头部 + 内边距约 96dp
            bodyCap = Math.max(UiKit.dp(ctx, 88), screenH / 4 - UiKit.dp(ctx, 96));
        } else {
            bodyCap = Math.max(UiKit.dp(ctx, 120), (int) (screenH * 0.55f));
        }
        MaxHeightScrollView scroller = new MaxHeightScrollView(ctx, bodyCap);
        scroller.setVerticalScrollBarEnabled(true);
        scroller.setFillViewport(false);
        scroller.addView(body, new android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setBackgroundDrawableResource(android.R.color.transparent);
            w.setGravity(Gravity.BOTTOM);
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT);
            // 淡化遮罩：上方文件列表要能看见，不能整屏糊住
            android.view.WindowManager.LayoutParams lp = w.getAttributes();
            lp.dimAmount = 0.35f;
            w.setAttributes(lp);
            w.addFlags(WindowManagerFlag.DIM_BEHIND);
        }
        dialog.show();
    }

    private static String allLabel(SelectionHost sel) {
        int total = sel.totalCount();
        return (total > 0 && sel.selectedCount() >= total) ? "取消全选" : "全选";
    }

    /** 高度上限为 AT_MOST 的 ScrollView：内容矮就按内容高，超过上限才滚动。 */
    private static final class MaxHeightScrollView extends ScrollView {
        private final int maxHeight;

        MaxHeightScrollView(Context ctx, int maxHeight) {
            super(ctx);
            this.maxHeight = Math.max(1, maxHeight);
        }

        @Override
        protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            int capped = MeasureSpec.makeMeasureSpec(maxHeight, MeasureSpec.AT_MOST);
            super.onMeasure(widthMeasureSpec, capped);
        }
    }

    /** 避免额外 import：WindowManager.LayoutParams.FLAG_DIM_BEHIND 的常量值。 */
    private static final class WindowManagerFlag {
        static final int DIM_BEHIND = 0x00000002;
    }

    /**
     * 库页多选的动作清单（顺序：先「匹配」类，再「编辑」类，最后「文件」类）。
     *
     * <p>每个动作都在**点击时**用 {@link SelectionHost#selectedFiles()} 现取文件，
     * 这样弹层里点了「全选」之后再执行动作，作用于的是最新选择集。
     */
    private static List<Item> buildSelectionItems(final MainActivity host, final SelectionHost sel) {
        List<Item> items = new java.util.ArrayList<Item>();
        items.add(new Item("批量匹配元数据", "联网匹配标题 / 歌手 / 专辑等字段，先预览再写入",
                new Runnable() {
                    @Override
                    public void run() {
                        BatchActions.tags(host, sel.selectedFiles(), host.batchMemory("tags"));
                    }
                }));
        items.add(new Item("批量匹配封面", "联网找封面，先预览再写入",
                new Runnable() {
                    @Override
                    public void run() {
                        BatchActions.covers(host, sel.selectedFiles(), host.batchMemory("cover"));
                    }
                }));
        items.add(new Item("批量匹配歌词", "联网找歌词，按设置写成 .lrc 和/或内嵌",
                new Runnable() {
                    @Override
                    public void run() {
                        BatchActions.lyrics(host, sel.selectedFiles(), host.batchMemory("lyrics"));
                    }
                }));
        items.add(new Item("批量编辑", "统一改字段、重排音轨号",
                new Runnable() {
                    @Override
                    public void run() {
                        BatchEditDialog.show(host, sel.selectedFiles());
                    }
                }));
        items.add(new Item("重命名", "按模板改名，可实时预览旧名 → 新名",
                new Runnable() {
                    @Override
                    public void run() {
                        BatchActions.renameByTag(host, sel.selectedFiles());
                    }
                }));
        items.add(new Item("歌词偏移", "整批统一加减毫秒，修歌词提前/滞后",
                new Runnable() {
                    @Override
                    public void run() {
                        LyricsShiftDialog.show(host, sel.selectedFiles());
                    }
                }));
        items.add(new Item("查看歌词", "看歌词轴与逐字时间（看选中的第一首）",
                new Runnable() {
                    @Override
                    public void run() {
                        List<VFile> f = sel.selectedFiles();
                        if (f.isEmpty()) {
                            host.toast("没有选中文件");
                            return;
                        }
                        LyricsViewerDialog.show(host, f.get(0));
                    }
                }));
        items.add(new Item("删除", "删掉选中的文件（不进回收站）",
                new Runnable() {
                    @Override
                    public void run() {
                        BatchActions.delete(host, sel.selectedFiles());
                    }
                }));
        return items;
    }
}
