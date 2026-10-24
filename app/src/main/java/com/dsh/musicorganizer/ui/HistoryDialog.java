package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.app.Dialog;
import android.content.Context;
import android.content.DialogInterface;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.Journal;
import com.dsh.musicorganizer.core.JournalHistory;
import com.dsh.musicorganizer.core.MoveJournal;
import com.dsh.musicorganizer.core.MoveLog;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.TagTransaction;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * 写入 / 整理历史 —— 两件事统一成一个「能反悔」的列表（v0.1.40）。
 *
 * <p>v0.1.30 只做了标签写入的批次列表，v0.1.39 又给整理加了移动日志，于是「撤销」散在两处。
 * 这里把两者按时间合并成一张表：
 *
 * <ul>
 *   <li><b>标签</b>：一列「标签」徽标，撤销 = 把改过的字段改回写入前（只动那批碰过的字段）；</li>
 *   <li><b>整理</b>：一列「整理」徽标，撤销 = 把文件搬回原目录原名（原位置被占加序号）。</li>
 * </ul>
 */
public final class HistoryDialog {

    private HistoryDialog() {
    }

    /** 列表里的一行（标签批次或整理批次）。 */
    private static final class Entry {
        boolean move;
        String key;
        String time;
        String title;
        String summary;
    }

    public static void show(final MainActivity host) {
        final Context ctx = host;
        final List<Entry> entries = load(host);
        if (entries.isEmpty()) {
            new UiKit.Builder(ctx)
                    .setTitle("撤销历史")
                    .setMessage("还没有可撤销的记录。\n\n"
                            + "· 批量打标签 / 歌词 / 编辑 → 记「标签」批次，撤销回滚改过的字段；\n"
                            + "· 自动整理 → 记「整理」批次，撤销把文件搬回原目录原名。")
                    .setPositiveButton("知道了", null)
                    .show();
            return;
        }

        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout root = UiKit.vertical(ctx);
        root.setBackgroundColor(UiKit.bgColor());
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);

        root.addView(UiKit.text(ctx, "撤销历史", 18, UiKit.textColor(), true));
        TextView hint = UiKit.caption(ctx,
                "标签写入与自动整理按时间合并列出（各取最近 40 批）。"
                        + "标签撤销只动那一批改过的字段；整理撤销把文件搬回原目录原名，"
                        + "原位置被占用的会加序号、不覆盖。");
        hint.setLineSpacing(UiKit.dp(ctx, 2), 1f);
        UiKit.margin(hint, 0, 6, 0, 8);
        root.addView(hint);

        final EntryAdapter adapter = new EntryAdapter(ctx, host, entries, dialog);
        ListView list = new ListView(ctx);
        list.setDivider(null);
        list.setDividerHeight(UiKit.dp(ctx, 6));
        list.setVerticalScrollBarEnabled(false);
        list.setAdapter(adapter);
        root.addView(list, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        Button close = UiKit.button(ctx, "关闭", false);
        close.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
            }
        });
        UiKit.margin(close, 0, 8, 0, 0);
        root.addView(close);

        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        }
        dialog.show();
    }

    /** 把标签批次与整理批次合并、按时间倒序、截断到 60 条。 */
    private static List<Entry> load(MainActivity host) {
        List<Entry> out = new ArrayList<Entry>();
        for (JournalHistory.Batch b : Journal.batches(host, 40)) {
            Entry e = new Entry();
            e.move = false;
            e.key = b.key;
            e.time = b.time;
            e.title = b.title();
            e.summary = b.summary();
            out.add(e);
        }
        for (MoveLog.Batch b : MoveJournal.batches(host, 40)) {
            Entry e = new Entry();
            e.move = true;
            e.key = b.batchId;
            e.time = b.time;
            e.title = b.title();
            e.summary = "自动整理搬动的文件（撤销 = 搬回原目录原名）";
            out.add(e);
        }
        Collections.sort(out, new Comparator<Entry>() {
            @Override
            public int compare(Entry a, Entry b) {
                return b.time.compareTo(a.time);
            }
        });
        if (out.size() > 60) {
            return new ArrayList<Entry>(out.subList(0, 60));
        }
        return out;
    }

    /** 撤销一批（确认 → 长任务 → 结束后刷新列表）。 */
    private static void revert(final MainActivity host, final Entry entry,
                               final EntryAdapter adapter) {
        String message = entry.move
                ? entry.title + "\n\n把这一批整理搬动的文件搬回原目录原名。"
                + "原位置被占用的会加序号（不覆盖现有文件）；已经被删掉或又搬走的会计入失败。"
                : entry.title + "\n\n" + entry.summary
                + "\n\n会把这一批改过的字段改回写入前的值，文件本身和没改过的字段都不动。";
        new UiKit.Builder(host)
                .setTitle(entry.move ? "撤销这批整理？" : "撤销这批写入？")
                .setMessage(message)
                .setNegativeButton("取消", null)
                .setPositiveButton(entry.move ? "搬回原位" : "整批撤销",
                        new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface d, int which) {
                                host.runTask(entry.move ? "撤销整理" : "撤销写入",
                                        new Tasks.Job() {
                                            @Override
                                            public Object run() throws Exception {
                                                Storage st = host.safeStorage();
                                                if (entry.move) {
                                                    return MoveJournal.revert(st, host,
                                                            entry.key, host);
                                                }
                                                return TagTransaction.revertBatch(st,
                                                        host.getContentResolver(), host,
                                                        entry.key, host);
                                            }
                                        }, new Tasks.Callback() {
                                            @Override
                                            public void done(Object result, Exception error) {
                                                if (error != null) {
                                                    host.fail(error);
                                                    return;
                                                }
                                                int[] r = (int[]) result;
                                                if (r[2] == 0) {
                                                    host.toast("该批次已全部撤销");
                                                } else {
                                                    host.toast((entry.move ? "搬回 " : "已撤销 ")
                                                            + r[0] + " 个"
                                                            + (r[1] > 0 ? "，失败 " + r[1] : ""));
                                                }
                                                host.invalidateScan();
                                                adapter.reload();
                                            }
                                        });
                            }
                        })
                .show();
    }

    private static final class EntryAdapter extends BaseAdapter {
        private final Context ctx;
        private final MainActivity host;
        private final List<Entry> items;
        private final Dialog dialog;

        EntryAdapter(Context ctx, MainActivity host, List<Entry> items, Dialog dialog) {
            this.ctx = ctx;
            this.host = host;
            this.items = items;
            this.dialog = dialog;
        }

        /** 撤销后重新读两份历史（批次可能整体消失）。 */
        void reload() {
            List<Entry> now = load(host);
            items.clear();
            items.addAll(now);
            notifyDataSetChanged();
            if (items.isEmpty()) {
                dialog.dismiss();
                host.toast("没有可撤销的记录了");
            }
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
        public View getView(int position, View convertView, ViewGroup parent) {
            final Entry e = items.get(position);
            LinearLayout card = UiKit.card(ctx);
            LinearLayout head = UiKit.horizontal(ctx);
            head.addView(UiKit.badge(ctx, e.move ? "整理" : "标签",
                    e.move ? UiKit.accentColor() : UiKit.primary()));
            TextView title = UiKit.text(ctx, e.title, 15, UiKit.textColor(), true);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            lp.setMargins(UiKit.dp(ctx, 6), 0, 0, 0);
            head.addView(title, lp);
            card.addView(head);
            TextView sub = UiKit.caption(ctx, e.summary);
            UiKit.margin(sub, 0, 4, 0, 0);
            card.addView(sub);
            Button undo = UiKit.button(ctx, e.move ? "搬回原位" : "撤销这批", false);
            UiKit.margin(undo, 0, 8, 0, 0);
            undo.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    revert(host, e, EntryAdapter.this);
                }
            });
            card.addView(undo);
            return card;
        }
    }
}
