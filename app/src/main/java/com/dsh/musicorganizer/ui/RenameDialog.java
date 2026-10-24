package com.dsh.musicorganizer.ui;

import android.app.Dialog;
import android.content.Context;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.NameTemplate;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 「按标签重命名」的可编辑模板版本（v0.1.31）。
 *
 * <p>以前格式写死成「艺人 - 歌名」，想改成「03. 晴天」没辙。现在：
 * 输入框写模板（{@code {artist}} / {@code {title}} / {@code {track}} …），
 * 点预设胶囊一键换格式，下面实时列出「旧名 → 新名」，确认后一次性改名。
 *
 * <p>标签是懒读的：打开面板先读前 200 首算预览，避免选 900 首时卡住；
 * 真正改名时逐首读（走长任务，可暂停/取消）。
 */
public final class RenameDialog {

    private RenameDialog() {
    }

    /** 预览上限：再多就只算前 N 个，避免一次性读几千个文件头。 */
    private static final int PREVIEW_LIMIT = 200;

    public static void show(final MainActivity host, final List<VFile> files) {
        if (files == null || files.isEmpty()) {
            host.toast("没有选中文件");
            return;
        }
        final Context ctx = host;
        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);

        LinearLayout root = UiKit.vertical(ctx);
        root.setBackgroundColor(UiKit.bgColor());
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);

        root.addView(UiKit.text(ctx, "按模板重命名", 18, UiKit.textColor(), true));
        TextView hint = UiKit.caption(ctx, NameTemplate.help()
                + " 冲突自动加「 (2)」；标题为空的文件会被跳过。");
        hint.setLineSpacing(UiKit.dp(ctx, 2), 1f);
        UiKit.margin(hint, 0, 6, 0, 8);
        root.addView(hint);

        // 模板输入框
        String saved = host.repo.str("rename_tpl", NameTemplate.DEFAULT);
        final EditText input = UiKit.input(ctx, NameTemplate.DEFAULT);
        input.setText(saved == null || saved.trim().isEmpty() ? NameTemplate.DEFAULT : saved);
        input.setSingleLine(true);
        root.addView(input);

        // 预设胶囊
        LinearLayout chips = UiKit.horizontal(ctx);
        chips.setGravity(Gravity.CENTER_VERTICAL);
        for (final String preset : NameTemplate.PRESETS) {
            TextView chip = UiKit.chip(ctx, preset, false);
            UiKit.margin(chip, 0, 6, 6, 0);
            chip.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    input.setText(preset);
                    input.setSelection(input.getText().length());
                }
            });
            chips.addView(chip);
        }
        root.addView(chips);

        final TextView count = UiKit.caption(ctx, "");
        UiKit.margin(count, 0, 8, 0, 4);
        root.addView(count);

        final Preview adapter = new Preview(ctx, host, files);
        ListView list = new ListView(ctx);
        list.setDivider(null);
        list.setDividerHeight(UiKit.dp(ctx, 4));
        list.setVerticalScrollBarEnabled(false);
        list.setAdapter(adapter);
        root.addView(list, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        final Button go = UiKit.button(ctx, "重命名", true);
        Button cancel = UiKit.button(ctx, "取消", false);

        final Runnable refresh = new Runnable() {
            @Override
            public void run() {
                String tpl = input.getText().toString();
                if (!adapter.isReady()) {
                    count.setText("共 " + files.size() + " 首 · 正在读取标签…");
                    go.setText("重命名");
                    go.setEnabled(false);
                    return;
                }
                adapter.render(tpl);
                int will = adapter.willRename();
                count.setText("共 " + files.size() + " 首 · 将改名 " + will + " 首"
                        + (files.size() > PREVIEW_LIMIT
                        ? " · 预览只算前 " + PREVIEW_LIMIT + " 首" : ""));
                go.setText(will > 0 ? "重命名 " + will + " 首" : "重命名");
                go.setEnabled(will > 0);
            }
        };
        adapter.onReady = refresh;
        adapter.preload();
        input.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {
            }

            @Override
            public void onTextChanged(CharSequence s, int a, int b, int c) {
            }

            @Override
            public void afterTextChanged(Editable s) {
                refresh.run();
            }
        });

        go.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                final String tpl = input.getText().toString().trim();
                host.repo.setStr("rename_tpl", tpl.isEmpty() ? NameTemplate.DEFAULT : tpl);
                dialog.dismiss();
                run(host, files, tpl.isEmpty() ? NameTemplate.DEFAULT : tpl);
            }
        });
        cancel.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
            }
        });
        UiKit.margin(go, 0, 8, 0, 0);
        root.addView(go);
        UiKit.margin(cancel, 0, 8, 0, 0);
        root.addView(cancel);

        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        }
        dialog.show();
        refresh.run();
    }

    /** 真正改名（长任务，可暂停/取消）。 */
    private static void run(final MainActivity host, final List<VFile> files,
                            final String pattern) {
        host.runTask("按模板重命名", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                VFile root = host.root();
                int renamed = 0;
                int skipped = 0;
                List<String> fails = new ArrayList<String>();
                for (VFile f : files) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    Tags tags = Scanner.readTagsCheap(st, host.getContentResolver(), f);
                    String target = NameTemplate.render(pattern, NameTemplate.fields(tags),
                            f.ext());
                    if (target.isEmpty() || target.equals(f.name)) {
                        skipped++;
                        continue;
                    }
                    VFile dir = Scanner.dirOf(st, root, f);
                    String cand = target;
                    int n = 2;
                    Map<String, Boolean> tried = new HashMap<String, Boolean>();
                    tried.put(cand, Boolean.TRUE);
                    while (st.findChild(dir, cand) != null) {
                        cand = NameTemplate.withIndex(target, n);
                        n++;
                        if (n > 999 || tried.containsKey(cand)) {
                            break;
                        }
                        tried.put(cand, Boolean.TRUE);
                    }
                    if (st.rename(f, cand)) {
                        Scanner.invalidate(f);
                        renamed++;
                    } else {
                        fails.add(f.name);
                    }
                }
                return new Object[]{Integer.valueOf(renamed), Integer.valueOf(skipped), fails};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                Object[] r = (Object[]) result;
                int renamed = ((Integer) r[0]).intValue();
                int skipped = ((Integer) r[1]).intValue();
                @SuppressWarnings("unchecked")
                List<String> fails = (List<String>) r[2];
                host.log("按模板重命名：成功 " + renamed + "，跳过 " + skipped
                        + "，失败 " + fails.size(), fails.isEmpty() ? "success" : "warning");
                for (int i = 0; i < Math.min(fails.size(), 5); i++) {
                    host.log("改名失败：" + fails.get(i), "error");
                }
                host.toast("已改名 " + renamed + " 首"
                        + (skipped > 0 ? "，跳过 " + skipped : "")
                        + (fails.isEmpty() ? "" : "，失败 " + fails.size()));
                host.invalidateScan();
            }
        });
    }

    /** 「旧名 → 新名」预览列表。 */
    private static final class Preview extends BaseAdapter {
        private final Context ctx;
        private final MainActivity host;
        private final List<VFile> files;
        private final List<String> olds = new ArrayList<String>();
        private final List<String> news = new ArrayList<String>();
        private final List<Map<String, String>> fields = new ArrayList<Map<String, String>>();
        private final List<String> exts = new ArrayList<String>();
        private boolean ready;
        private Runnable onReady = new Runnable() {
            @Override
            public void run() {
            }
        };
        private int willRename;

        Preview(Context ctx, MainActivity host, List<VFile> files) {
            this.ctx = ctx;
            this.host = host;
            this.files = files;
        }

        /**
         * 后台把前 PREVIEW_LIMIT 首的标签读进缓存（只读一次）。
         * 之后改模板只是纯计算，换一个字就重算一遍也不会卡。
         */
        void preload() {
            final int limit = Math.min(files.size(), PREVIEW_LIMIT);
            new Thread(new Runnable() {
                @Override
                public void run() {
                    List<Map<String, String>> fcache = new ArrayList<Map<String, String>>();
                    List<String> ecache = new ArrayList<String>();
                    try {
                        Storage st = host.safeStorage();
                        for (int i = 0; i < limit; i++) {
                            VFile f = files.get(i);
                            Map<String, String> m;
                            try {
                                m = NameTemplate.fields(Scanner.readTagsCheap(st,
                                        host.getContentResolver(), f));
                            } catch (Exception e) {
                                m = new HashMap<String, String>();
                            }
                            fcache.add(m);
                            ecache.add(f.ext());
                        }
                    } catch (Exception ignored) {
                    }
                    final List<Map<String, String>> fc = fcache;
                    final List<String> ec = ecache;
                    host.runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            fields.clear();
                            fields.addAll(fc);
                            exts.clear();
                            exts.addAll(ec);
                            ready = true;
                            onReady.run();
                        }
                    });
                }
            }).start();
        }

        /** 换模板只做纯计算。 */
        void render(String pattern) {
            olds.clear();
            news.clear();
            willRename = 0;
            for (int i = 0; i < fields.size(); i++) {
                    VFile f = files.get(i);
                    String name = NameTemplate.render(pattern, fields.get(i),
                            i < exts.size() ? exts.get(i) : f.ext());
                    if (!name.isEmpty() && !name.equals(f.name)) {
                        willRename++;
                    }
                olds.add(f.name);
                news.add(name);
            }
            notifyDataSetChanged();
        }

        int willRename() {
            return willRename;
        }

        boolean isReady() {
            return ready;
        }

        @Override
        public int getCount() {
            return olds.size();
        }

        @Override
        public Object getItem(int position) {
            return news.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            LinearLayout box = UiKit.vertical(ctx);
            int pad = UiKit.dp(ctx, 8);
            box.setPadding(pad, pad, pad, pad);
            String oldName = olds.get(position);
            String newName = news.get(position);
            boolean same = newName.isEmpty() || newName.equals(oldName);
            box.addView(UiKit.text(ctx, oldName, 13,
                    same ? UiKit.subColor() : UiKit.bodyColor(), false));
            TextView next = UiKit.text(ctx,
                    newName.isEmpty() ? "（跳过：标题为空）"
                            : (same ? "（不变）" : "→ " + newName),
                    13, same ? UiKit.subColor() : UiKit.primary(), !same);
            UiKit.margin(next, 0, 2, 0, 0);
            box.addView(next);
            return box;
        }
    }
}
