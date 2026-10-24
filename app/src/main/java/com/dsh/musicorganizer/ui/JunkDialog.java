package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.Junk;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 垃圾文件清理（v0.1.38）。
 *
 * <p>列出 {@link Junk#plan} 挑出来的候选（0 字节、`.lrc.bak`、临时文件、系统垃圾），
 * 默认全勾，用户可取消；删除前二次确认，说明**不进回收站、不可恢复**。
 */
public final class JunkDialog {

    private JunkDialog() {
    }

    private static final class Row {
        final Junk.Item item;
        final CheckBox box;
        final View view; // 整行视图只构建一次，避免 getView 重复 addView 同一 CheckBox 报 parent 冲突

        Row(Junk.Item item, CheckBox box, View view) {
            this.item = item;
            this.box = box;
            this.view = view;
        }
    }

    public static void show(final MainActivity host) {
        final Context ctx = host;
        if (host.repo.treeUri() == null) {
            new UiKit.Builder(ctx)
                    .setTitle("清理垃圾文件")
                    .setMessage("请先在首页选择一个音乐目录，再回来清理垃圾文件。")
                    .setPositiveButton("知道了", null)
                    .show();
            return;
        }
        // 递归遍历整棵目录树（含非音乐文件），这样 .lrc.bak / .tmp / Thumbs.db 才扫得到。
        // 旧逻辑只扫 lastFiles（仅音乐文件），导致歌词备份永远清不掉。
        host.runTask("扫描垃圾文件", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                VFile root = host.root();
                List<VFile> all = Scanner.walkAll(st, root, null, host.cancelToken());
                return Junk.plan(all);
            }
        }, new Tasks.Callback() {
            @Override
            @SuppressWarnings("unchecked")
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                build(host, (List<Junk.Item>) result);
            }
        });
    }

    private static void build(final MainActivity host, final List<Junk.Item> items) {
        final Context ctx = host;

        if (items.isEmpty()) {
            new UiKit.Builder(ctx)
                    .setTitle("清理垃圾文件")
                    .setMessage("没有发现垃圾文件。\n\n"
                            + "检查范围：0 字节的音频/歌词、.lrc.bak 歌词备份、"
                            + ".tmp/.part/.crdownload 之类的临时文件、"
                            + "Thumbs.db / .DS_Store / desktop.ini 这类系统垃圾。")
                    .setPositiveButton("知道了", null)
                    .show();
            return;
        }

        final List<Row> rows = new ArrayList<Row>();
        LinearLayout root = UiKit.vertical(ctx);
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);
        root.setBackgroundColor(UiKit.bgColor());

        root.addView(UiKit.text(ctx, "清理垃圾文件", 18, UiKit.textColor(), true));
        TextView hint = UiKit.caption(ctx,
                Junk.summary(items) + "。删除不进回收站，确认前请看清楚。");
        hint.setLineSpacing(UiKit.dp(ctx, 2), 1f);
        UiKit.margin(hint, 0, 6, 0, 8);
        root.addView(hint);

        // 按原因分组显示数量
        Map<String, Integer> byReason = Junk.byReason(items);
        for (Map.Entry<String, Integer> e : byReason.entrySet()) {
            TextView t = UiKit.caption(ctx, "· " + e.getKey() + "：" + e.getValue() + " 个");
            root.addView(t);
        }

        final JunkAdapter adapter = new JunkAdapter(ctx, items, rows);
        ListView list = new ListView(ctx);
        list.setDivider(null);
        list.setDividerHeight(UiKit.dp(ctx, 4));
        list.setVerticalScrollBarEnabled(false);
        list.setAdapter(adapter);
        root.addView(list, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        final TextView count = UiKit.caption(ctx, "");
        UiKit.margin(count, 0, 6, 0, 6);
        root.addView(count);

        final Button del = UiKit.button(ctx, "删除选中", true);
        Button cancel = UiKit.button(ctx, "取消", false);
        UiKit.margin(del, 0, 0, 0, 6);
        root.addView(del);
        root.addView(cancel);

        // 用全屏 Dialog 而不是 AlertDialog：AlertDialog 会把自定义布局塞进一层 ScrollView，
        // 里面「高度 0 + weight 1」的 ListView 拿不到剩余高度，列表会变成 0 高看不见
        // （v0.1.42 的媒体库面板踩过一次，这里是同一个坑）。
        final android.app.Dialog dialog = new android.app.Dialog(ctx);
        dialog.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        dialog.setContentView(root);
        android.view.Window dw = dialog.getWindow();
        if (dw != null) {
            dw.setLayout(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT);
        }
        dialog.show();

        final Runnable refresh = new Runnable() {
            @Override
            public void run() {
                del.setText("删除选中 " + adapter.checkedCount() + " 个");
                del.setEnabled(adapter.checkedCount() > 0);
                count.setText("已选 " + adapter.checkedCount() + "/" + items.size()
                        + " 个 · 释放 " + com.dsh.musicorganizer.core.HealthCheck.size(
                        adapter.checkedSize()));
            }
        };
        adapter.onChange = refresh;
        refresh.run();

        del.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                final List<Junk.Item> selected = adapter.checked();
                if (selected.isEmpty()) {
                    host.toast("没有勾选任何文件");
                    return;
                }
                new UiKit.Builder(ctx)
                        .setTitle("确认删除")
                        .setMessage("将永久删除 " + selected.size() + " 个文件（"
                                + com.dsh.musicorganizer.core.HealthCheck.size(
                                Junk.totalSize(selected)) + "）。\n\n"
                                + "这些文件不进回收站，删掉找不回来。只删上面列出的垃圾，"
                                + "音频与正常歌词不在其中。")
                        .setNegativeButton("取消", null)
                        .setPositiveButton("永久删除", new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface d, int which) {
                                dialog.dismiss();
                                run(host, selected);
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

    private static void run(final MainActivity host, final List<Junk.Item> items) {
        host.runTask("清理垃圾文件", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                int deleted = 0;
                int failed = 0;
                long freed = 0;
                List<String> errors = new ArrayList<String>();
                for (Junk.Item it : items) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    boolean ok;
                    try {
                        ok = st.delete(it.file);
                    } catch (Exception e) {
                        ok = false;
                    }
                    if (ok) {
                        deleted++;
                        freed += it.size();
                    } else {
                        failed++;
                        if (errors.size() < 20) {
                            errors.add(it.file.name + "（" + it.reason + "）");
                        }
                    }
                }
                return new Object[]{Integer.valueOf(deleted), Integer.valueOf(failed),
                        Long.valueOf(freed), errors};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                Object[] r = (Object[]) result;
                int deleted = ((Integer) r[0]).intValue();
                int failed = ((Integer) r[1]).intValue();
                long freed = ((Long) r[2]).longValue();
                @SuppressWarnings("unchecked")
                List<String> errors = (List<String>) r[3];
                host.log("清理垃圾：" + deleted + " 个，释放 "
                        + com.dsh.musicorganizer.core.HealthCheck.size(freed)
                        + (failed > 0 ? "，失败 " + failed + " 个" : ""),
                        failed > 0 ? "warning" : "success");
                for (int i = 0; i < Math.min(errors.size(), 5); i++) {
                    host.log("删除失败：" + errors.get(i), "error");
                }
                host.toast("已删除 " + deleted + " 个，释放 "
                        + com.dsh.musicorganizer.core.HealthCheck.size(freed)
                        + (failed > 0 ? "，失败 " + failed : ""));
                host.invalidateScan();
            }
        });
    }

    private static final class JunkAdapter extends BaseAdapter {
        private final Context ctx;
        private final List<Junk.Item> items;
        private final List<Row> rows;
        Runnable onChange;

        JunkAdapter(Context ctx, List<Junk.Item> items, List<Row> rows) {
            this.ctx = ctx;
            this.items = items;
            this.rows = rows;
            for (Junk.Item it : items) {
                final CheckBox box = UiKit.checkbox(ctx, "", true);
                box.setOnCheckedChangeListener(new android.widget.CompoundButton
                        .OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(android.widget.CompoundButton b, boolean v) {
                        if (onChange != null) {
                            onChange.run();
                        }
                    }
                });
                // 整行视图只构建一次并缓存，CheckBox 只 addView 一次，避免复用报 parent 冲突
                LinearLayout vbox = UiKit.vertical(ctx);
                LinearLayout head = UiKit.horizontal(ctx);
                head.addView(box);
                TextView name = UiKit.text(ctx, it.file.name, 14, UiKit.textColor(), false);
                head.addView(name, new LinearLayout.LayoutParams(0,
                        LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
                vbox.addView(head);
                TextView why = UiKit.caption(ctx, it.reason + " · " + it.sizeText());
                UiKit.margin(why, 0, 2, 0, 0);
                vbox.addView(why);
                rows.add(new Row(it, box, vbox));
            }
        }

        List<Junk.Item> checked() {
            List<Junk.Item> out = new ArrayList<Junk.Item>();
            for (Row r : rows) {
                if (r.box.isChecked()) {
                    out.add(r.item);
                }
            }
            return out;
        }

        int checkedCount() {
            int n = 0;
            for (Row r : rows) {
                if (r.box.isChecked()) {
                    n++;
                }
            }
            return n;
        }

        long checkedSize() {
            long sum = 0;
            for (Row r : rows) {
                if (r.box.isChecked()) {
                    sum += r.item.size();
                }
            }
            return sum;
        }

        @Override
        public int getCount() {
            return rows.size();
        }

        @Override
        public Object getItem(int position) {
            return rows.get(position).item;
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            // 行视图在构造时已构建并缓存到 Row.view，这里直接复用，
            // 不再每次 new 容器重复 addView 同一个 CheckBox（否则滚动复用会报 parent 冲突）
            return rows.get(position).view;
        }
    }
}
