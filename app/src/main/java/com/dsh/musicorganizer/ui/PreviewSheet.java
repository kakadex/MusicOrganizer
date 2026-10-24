package com.dsh.musicorganizer.ui;

import android.app.Dialog;
import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import java.util.List;

/**
 * 统一的「写入前预览」全屏面板：先看「旧值 → 新值」再决定写不写。
 *
 * <p>标签 / 歌词 / 封面 三处联网匹配结果都走这里：<b>先预览、逐条勾选、全选/全不选/反选，
 * 只有勾选中的才写盘</b>。之前三处各写一套 {@code AlertDialog.setMultiChoiceItems}，
 * 没有全选、没有反选、条目挤成一片，操作逻辑也不一致；现在合成一个。
 */
public final class PreviewSheet {

    private PreviewSheet() {
    }

    /** 一行预览数据。实现方把 {@code selected} 直接落到真实 Match 上（写盘读的是 Match.selected）。 */
    public interface Item {
        boolean isSelected();

        void setSelected(boolean v);

        /** 第一行：文件名。 */
        String title();

        /** 第二行：匹配结果摘要（候选 / 字段对比 / 来源 · 置信度）。 */
        String subtitle();

        /** 低置信 → 行内亮「⚠低置信」。 */
        boolean warn();

        /** 明细全文；空则这一行没有「明细」入口。 */
        String detail();
    }

    /** 点「写入选中」后回调（此时各 Item 的 selected 已就绪，调用方自行过滤）。 */
    public interface Callback {
        void onConfirm();
    }

    public static void show(final MainActivity host, final String title, final String hint,
                            final List<Item> items, final String confirmLabel,
                            final String cancelLabel, final Callback cb) {
        final Context ctx = host;
        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);

        LinearLayout root = UiKit.vertical(ctx);
        root.setBackgroundColor(UiKit.bgColor());
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);

        // 标题
        TextView titleView = UiKit.text(ctx, title, 18, UiKit.textColor(), true);
        root.addView(titleView);
        // 说明
        if (hint != null && !hint.trim().isEmpty()) {
            TextView hintView = UiKit.caption(ctx, hint.trim());
            hintView.setLineSpacing(UiKit.dp(ctx, 2), 1f);
            UiKit.margin(hintView, 0, 6, 0, 8);
            root.addView(hintView);
        }

        // 这些要在控制行 / 底部按钮 / 列表行的回调里被读，先声明
        final TextView count = UiKit.caption(ctx, "");
        final Button confirm = UiKit.button(ctx, confirmLabel, true);

        final Runnable refresh = new Runnable() {
            @Override
            public void run() {
                int n = selectedCount(items);
                count.setText("已选 " + n + "/" + items.size());
                confirm.setText(n > 0 ? confirmLabel + " " + n + " 首" : confirmLabel);
            }
        };
        final RowAdapter rowAdapter = new RowAdapter(ctx, items, host, refresh);

        // 选择控制行：全选 / 全不选 / 反选 + 已选计数
        LinearLayout ctrl = UiKit.horizontal(ctx);
        ctrl.setGravity(Gravity.CENTER_VERTICAL);
        ctrl.addView(ctrlButton(ctx, "全选", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                setAll(items, true);
                rowAdapter.notifyDataSetChanged();
                refresh.run();
            }
        }));
        ctrl.addView(ctrlButton(ctx, "全不选", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                setAll(items, false);
                rowAdapter.notifyDataSetChanged();
                refresh.run();
            }
        }));
        ctrl.addView(ctrlButton(ctx, "反选", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                for (Item it : items) {
                    it.setSelected(!it.isSelected());
                }
                rowAdapter.notifyDataSetChanged();
                refresh.run();
            }
        }));
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        ctrl.addView(count, clp);
        UiKit.margin(ctrl, 0, 0, 0, 8);
        root.addView(ctrl);

        // 列表
        final ListView list = new ListView(ctx);
        list.setDivider(null);
        list.setDividerHeight(UiKit.dp(ctx, 6));
        list.setVerticalScrollBarEnabled(false);
        list.setAdapter(rowAdapter);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        root.addView(list, llp);

        // 底部操作
        confirm.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                int n = selectedCount(items);
                if (n == 0) {
                    host.toast("没有勾选任何条目");
                    return;
                }
                dialog.dismiss();
                cb.onConfirm();
            }
        });
        UiKit.margin(confirm, 0, 8, 0, 0);
        root.addView(confirm);
        Button cancel = UiKit.button(ctx, cancelLabel, false);
        cancel.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
            }
        });
        UiKit.margin(cancel, 0, 8, 0, 0);
        root.addView(cancel);

        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        }
        refresh.run();
        dialog.show();
    }

    private static void setAll(List<Item> items, boolean v) {
        for (Item it : items) {
            it.setSelected(v);
        }
    }

    private static int selectedCount(List<Item> items) {
        int n = 0;
        for (Item it : items) {
            if (it.isSelected()) {
                n++;
            }
        }
        return n;
    }

    private static TextView ctrlButton(Context ctx, String label, View.OnClickListener onClick) {
        TextView b = UiKit.chip(ctx, label, false);
        UiKit.margin(b, 0, 0, 8, 0);
        b.setOnClickListener(onClick);
        return b;
    }

    // ------------------------------------------------------------------
    // 行
    // ------------------------------------------------------------------

    private static final class RowAdapter extends BaseAdapter {
        private final Context ctx;
        private final List<Item> items;
        private final MainActivity host;
        private final Runnable onChanged;

        RowAdapter(Context ctx, List<Item> items, MainActivity host, Runnable onChanged) {
            this.ctx = ctx;
            this.items = items;
            this.host = host;
            this.onChanged = onChanged;
        }

        @Override
        public int getCount() {
            return items.size();
        }

        @Override
        public Object getItem(int position) {
            return items.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(final int position, View convertView, ViewGroup parent) {
            final Holder h;
            if (convertView == null) {
                convertView = buildRow();
                h = new Holder(convertView);
                convertView.setTag(h);
            } else {
                h = (Holder) convertView.getTag();
            }
            final Item it = items.get(position);
            h.check.setChecked(it.isSelected());
            h.title.setText(it.title());
            h.sub.setText(it.subtitle());
            h.warn.setVisibility(it.warn() ? View.VISIBLE : View.GONE);

            final boolean hasDetail = it.detail() != null && !it.detail().trim().isEmpty();
            h.detail.setVisibility(hasDetail ? View.VISIBLE : View.GONE);
            h.detail.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    showDetail(host, it.title(), it.detail());
                }
            });

            View.OnClickListener toggle = new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    it.setSelected(!it.isSelected());
                    notifyDataSetChanged();
                    if (onChanged != null) {
                        onChanged.run();
                    }
                }
            };
            h.check.setOnClickListener(toggle);
            h.title.setOnClickListener(toggle);
            h.sub.setOnClickListener(toggle);
            return convertView;
        }

        private View buildRow() {
            LinearLayout row = UiKit.horizontal(ctx);
            row.setGravity(Gravity.CENTER_VERTICAL);
            int pv = UiKit.dp(ctx, 10);
            int ph = UiKit.dp(ctx, 8);
            row.setPadding(ph, pv, ph, pv);
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(UiKit.cardColor());
            bg.setCornerRadius(UiKit.dp(ctx, 10));
            row.setBackground(bg);

            CheckBox cb = new CheckBox(ctx);
            row.addView(cb);

            LinearLayout mid = UiKit.vertical(ctx);
            mid.setPadding(UiKit.dp(ctx, 8), 0, 0, 0);
            TextView title = UiKit.text(ctx, "", 14, UiKit.textColor(), true);
            TextView sub = UiKit.caption(ctx, "");
            mid.addView(title);
            mid.addView(sub);
            LinearLayout.LayoutParams midLp = new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            row.addView(mid, midLp);

            TextView warn = UiKit.badge(ctx, "⚠低置信", UiKit.errColor());
            UiKit.margin(warn, 0, 0, 6, 0);
            row.addView(warn);

            TextView detail = UiKit.chip(ctx, "明细", false);
            row.addView(detail);
            return row;
        }
    }

    /** 按构建时的固定子视图顺序取控件（buildRow 是唯一构建处）。 */
    private static final class Holder {
        final CheckBox check;
        final TextView title;
        final TextView sub;
        final TextView warn;
        final TextView detail;

        Holder(View row) {
            LinearLayout r = (LinearLayout) row;
            check = (CheckBox) r.getChildAt(0);
            LinearLayout mid = (LinearLayout) r.getChildAt(1);
            title = (TextView) mid.getChildAt(0);
            sub = (TextView) mid.getChildAt(1);
            warn = (TextView) r.getChildAt(2);
            detail = (TextView) r.getChildAt(3);
        }
    }

    private static void showDetail(MainActivity host, String title, String detail) {
        TextView tv = new TextView(host);
        tv.setText(detail);
        tv.setTextSize(12);
        tv.setTextColor(UiKit.bodyColor());
        tv.setTextIsSelectable(true);
        int pad = UiKit.dp(host, 14);
        tv.setPadding(pad, pad, pad, pad);
        android.widget.ScrollView scroll = new android.widget.ScrollView(host);
        scroll.addView(tv, new android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.WRAP_CONTENT));
        new UiKit.Builder(host)
                .setTitle(title)
                .setView(scroll)
                .setPositiveButton("返回", null)
                .show();
    }
}
