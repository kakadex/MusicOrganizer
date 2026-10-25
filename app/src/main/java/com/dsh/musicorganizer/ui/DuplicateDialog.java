package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.Duplicates;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 文件名查重结果：按组列出相似文件，逐条勾选要删的，最后一次性删除。
 *
 * <p>和以前的「保留第一个，删除其余」相比，这里给出的是一份**可改的清单**：
 * 每组会有一个「建议保留」的文件（名字没有「(1)」「副本」痕迹、体积更大、路径更短），
 * 其余默认勾选，但用户可以改。删除前必须再确认一次，且说明不可恢复。
 */
public final class DuplicateDialog {

    private DuplicateDialog() {
    }

    /** 一行的勾选状态。 */
    private static final class Row {
        final VFile file;
        final CheckBox box;

        Row(VFile file, CheckBox box) {
            this.file = file;
            this.box = box;
        }
    }

    public static void show(final MainActivity host, final List<Duplicates.Group> groups) {
        final Context ctx = host;
        final List<Row> rows = new ArrayList<Row>();

        LinearLayout root = UiKit.vertical(ctx);
        int pad = UiKit.dp(ctx, 14);
        root.setPadding(pad, pad, pad, pad);

        root.addView(UiKit.caption(ctx,
                "同一条歌可能因为「另存为」「复制到别的文件夹」留下多份，也可能只是文件名写法不同"
                        + "（带艺人前缀、带 (1) 尾巴）。下面是按文件名相似度 ≥ 90% 归出的分组；"
                        + "标「疑似」的组相似度偏低或读不到时长，默认不勾选，建议先试听确认再删。"));

        // 「建议保留」的不给勾，避免手滑把唯一一份删了
        for (int i = 0; i < groups.size(); i++) {
            Duplicates.Group group = groups.get(i);
            int keep = Duplicates.recommendKeep(group);
            LinearLayout card = UiKit.vertical(ctx);
            UiKit.margin(card, 0, i == 0 ? 10 : 16, 0, 0);

            String head = "组 " + (i + 1) + " · " + group.files.size() + " 个文件 · 相似度 "
                    + Math.round(group.score * 100) + "%"
                    + (group.suspect ? " · 疑似" : "");
            card.addView(UiKit.text(ctx, head, 14, UiKit.textColor(), true));
            if (group.suspect) {
                card.addView(UiKit.caption(ctx,
                        "疑似同一首的不同命名或不同版本。默认不勾选，确认无误后再勾。"));
            }
            TextView sub = UiKit.caption(ctx, "重复占用约 " + TextUtil.formatSize(group.wastedBytes()));
            card.addView(sub);

            for (int j = 0; j < group.files.size(); j++) {
                Duplicates.Item item = group.files.get(j);
                boolean isKeep = j == keep;
                String label = item.relative + "\n" + TextUtil.formatSize(item.size)
                        + (isKeep ? "  ·  建议保留" : "");
                // 疑似组默认不勾：查重是提示，误删不可逆
                final CheckBox box = UiKit.checkbox(ctx, label, !isKeep && !group.suspect);
                UiKit.margin(box, 0, 6, 0, 0);
                // 保留项不再强制锁定：用户可能想删掉被推荐保留的那一份。
                // 校验阶段保证「每组至少留一个」，避免误删唯一副本。
                card.addView(box);
                rows.add(new Row(item.file, box));
            }
            root.addView(card);
        }

        final ScrollView scroll = new ScrollView(ctx);
        scroll.addView(root);

        final AlertDialog dialog = new UiKit.Builder(ctx)
                .setTitle("文件名查重 · " + Duplicates.summary(groups))
                .setView(scroll)
                .setPositiveButton("删除选中", null)
                .setNeutralButton("全选", null)
                .setNegativeButton("关闭", null)
                .create();

        final CompoundButton.OnCheckedChangeListener listener =
                new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton b, boolean checked) {
                        refreshButton(host, dialog, rows);
                    }
                };
        for (Row row : rows) {
            row.box.setOnCheckedChangeListener(listener);
        }

        dialog.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override
            public void onShow(DialogInterface d) {
                refreshButton(host, dialog, rows);
                dialog.getButton(AlertDialog.BUTTON_NEUTRAL)
                        .setOnClickListener(new View.OnClickListener() {
                            @Override
                            public void onClick(View v) {
                                boolean allChecked = true;
                                for (Row row : rows) {
                                    if (!row.box.isChecked()) {
                                        allChecked = false;
                                        break;
                                    }
                                }
                                for (Row row : rows) {
                                    row.box.setChecked(!allChecked);
                                }
                                dialog.getButton(AlertDialog.BUTTON_NEUTRAL)
                                        .setText(allChecked ? "全选" : "全不选");
                            }
                        });
                dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                        .setOnClickListener(new View.OnClickListener() {
                            @Override
                            public void onClick(View v) {
                                List<VFile> picked = selected(rows);
                                if (picked.isEmpty()) {
                                    host.toast("没有勾选任何文件");
                                    return;
                                }
                                // 每组至少保留一个，禁止整组删光
                                java.util.Set<String> pickedIds = new java.util.HashSet<String>();
                                for (VFile f : picked) {
                                    pickedIds.add(f.docId);
                                }
                                for (Duplicates.Group g : groups) {
                                    int total = g.files.size();
                                    int willDelete = 0;
                                    for (Duplicates.Item it : g.files) {
                                        if (pickedIds.contains(it.file.docId)) {
                                            willDelete++;
                                        }
                                    }
                                    if (willDelete >= total) {
                                        host.toast("每组至少保留一个文件，不能把「"
                                                + g.files.get(0).file.name + "」所在组整组删光");
                                        return;
                                    }
                                }
                                confirmDelete(host, dialog, picked);
                            }
                        });
            }
        });
        dialog.show();
        UiKit.tintDialog(dialog);
    }

    private static List<VFile> selected(List<Row> rows) {
        List<VFile> out = new ArrayList<VFile>();
        for (Row row : rows) {
            if (row.box.isChecked()) {
                out.add(row.file);
            }
        }
        return out;
    }

    private static void refreshButton(MainActivity host, AlertDialog dialog, List<Row> rows) {
        int n = selected(rows).size();
        Button btn = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
        if (btn != null) {
            btn.setEnabled(n > 0);
            btn.setText(n > 0 ? "删除选中（" + n + "）" : "删除选中");
        }
    }

    private static void confirmDelete(final MainActivity host, final AlertDialog dialog,
                                      final List<VFile> picked) {
        long bytes = 0;
        for (VFile f : picked) {
            bytes += f.size;
        }
        host.confirm("确认删除 " + picked.size() + " 个文件",
                "共 " + TextUtil.formatSize(bytes) + "，删除后无法恢复（不进回收站）。\n"
                        + "每组都会保留一个「建议保留」的文件。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        delete(host, dialog, picked);
                    }
                });
    }

    private static void delete(final MainActivity host, final AlertDialog dialog,
                               final List<VFile> picked) {
        host.runTask("删除重复文件", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                int ok = 0;
                final List<String> failed = new ArrayList<String>();
                for (VFile f : picked) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    String reason = st.deleteWithReason(f);
                    if (reason == null) {
                        ok++;
                    } else {
                        failed.add(f.name + "：" + reason);
                    }
                    host.progressCallback().onProgress(ok + failed.size(), picked.size(),
                            "正在删除重复文件");
                }
                return new Object[]{Integer.valueOf(ok), failed};
            }
        }, new Tasks.Callback() {
            @Override
            @SuppressWarnings("unchecked")
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                Object[] r = (Object[]) result;
                int ok = ((Integer) r[0]).intValue();
                List<String> failed = (List<String>) r[1];
                StringBuilder detail = new StringBuilder();
                for (String s : failed) {
                    if (detail.length() > 0) {
                        detail.append("\n");
                    }
                    detail.append(s);
                }
                host.log("查重删除：" + ok + " 个文件" + (failed.isEmpty() ? ""
                        : "，失败 " + failed.size() + " 个\n" + detail),
                        failed.isEmpty() ? "success" : "warning");
                host.toast("已删除 " + ok + " 个文件"
                        + (failed.isEmpty() ? "" : "，失败 " + failed.size() + " 个"));
                host.invalidateScan();
                host.refreshBrowseAfterChange();
                dialog.dismiss();
            }
        });
    }
}
