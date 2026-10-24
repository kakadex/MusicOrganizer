package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.DialogInterface;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.BatchEdit;
import com.dsh.musicorganizer.core.TagIO;
import com.dsh.musicorganizer.core.TagTransaction;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 批量编辑：多选后统一改字段（整张专辑改专辑名 / 流派，或从 1 开始重排音轨号）。
 *
 * <p>与「在线匹配」互补：匹配是逐首先搜再确认，这里是人为指定同一值。
 * 只写用户勾选的字段 —— 没勾的字段一个字节都不动，避免误清标签。
 * 写盘走 {@link TagTransaction}（带 batchId，可在「安全网」里整批撤销）。
 */
public final class BatchEditDialog {

    private BatchEditDialog() {
    }

    public static void show(final MainActivity host, final List<VFile> files) {
        if (files == null || files.isEmpty()) {
            host.toast("先选中要修改的文件");
            return;
        }
        // 只处理能写标签的格式：M4A/WAV/OGG 现在都支持，这里过滤只是防目录项混进来
        final List<VFile> targets = new ArrayList<VFile>();
        for (VFile f : files) {
            if (!f.dir && TagIO.canWrite(f.ext())) {
                targets.add(f);
            }
        }
        if (targets.isEmpty()) {
            host.toast("选中的文件都不支持写标签");
            return;
        }

        ScrollView scroll = new ScrollView(host);
        LinearLayout box = UiKit.vertical(host);
        int pad = UiKit.dp(host, 16);
        box.setPadding(pad, UiKit.dp(host, 8), pad, UiKit.dp(host, 8));
        scroll.addView(box);

        box.addView(UiKit.caption(host,
                "选中 " + targets.size() + " 首。只写入勾选的字段，未勾选的保持原样；"
                        + "留空表示清除该字段。"));

        final Map<String, CheckBox> checks = new LinkedHashMap<String, CheckBox>();
        final Map<String, EditText> inputs = new LinkedHashMap<String, EditText>();
        for (String field : BatchEdit.FIELDS) {
            LinearLayout row = UiKit.horizontal(host);
            row.setGravity(android.view.Gravity.CENTER_VERTICAL);
            UiKit.margin(row, 0, 10, 0, 0);
            String label = Tags.LABELS.get(field);
            CheckBox cb = UiKit.checkbox(host, label == null ? field : label, false);
            cb.setMinWidth(UiKit.dp(host, 88));
            EditText et = new EditText(host);
            et.setHint(label == null ? field : label);
            et.setSingleLine(true);
            et.setTextSize(15);
            et.setInputType("year".equals(field) || "track".equals(field)
                    ? InputType.TYPE_CLASS_NUMBER : InputType.TYPE_CLASS_TEXT);
            et.setEnabled(false);
            cb.setOnCheckedChangeListener(new android.widget.CompoundButton.OnCheckedChangeListener() {
                @Override
                public void onCheckedChanged(android.widget.CompoundButton b, boolean checked) {
                    et.setEnabled(checked);
                    if (checked) {
                        et.requestFocus();
                    }
                }
            });
            row.addView(cb);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            row.addView(et, lp);
            checks.put(field, cb);
            inputs.put(field, et);
            box.addView(row);
        }

        // 音轨号：单独一行（不是「统一值」，而是按顺序递增）
        box.addView(UiKit.divider(host));
        LinearLayout trackRow = UiKit.horizontal(host);
        trackRow.setGravity(android.view.Gravity.CENTER_VERTICAL);
        final CheckBox cbTrack = UiKit.checkbox(host, "重排音轨号", false);
        cbTrack.setMinWidth(UiKit.dp(host, 88));
        final EditText etTrack = new EditText(host);
        etTrack.setText("1");
        etTrack.setHint("起始编号");
        etTrack.setInputType(InputType.TYPE_CLASS_NUMBER);
        etTrack.setEnabled(false);
        cbTrack.setOnCheckedChangeListener(new android.widget.CompoundButton.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(android.widget.CompoundButton b, boolean checked) {
                etTrack.setEnabled(checked);
            }
        });
        trackRow.addView(cbTrack);
        trackRow.addView(etTrack, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        box.addView(trackRow);
        box.addView(UiKit.caption(host,
                "按当前列表顺序从起始编号递增写入（多碟第二碟可以从 11 开始）。"));

        final AlertDialog dialog = new UiKit.Builder(host)
                .setTitle("批量编辑")
                .setView(scroll)
                .setNegativeButton("取消", null)
                .setPositiveButton("应用", null)
                .create();
        dialog.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override
            public void onShow(DialogInterface d) {
                Button ok = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
                ok.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        BatchEdit.Spec spec = new BatchEdit.Spec();
                        for (String field : BatchEdit.FIELDS) {
                            if (checks.get(field).isChecked()) {
                                spec.values.put(field, inputs.get(field).getText().toString().trim());
                            }
                        }
                        if (cbTrack.isChecked()) {
                            spec.renumberTrack = true;
                            spec.trackStart = parseInt(etTrack.getText().toString(), 1);
                        }
                        if (spec.isEmpty()) {
                            host.toast("至少勾选一个字段");
                            return;
                        }
                        dialog.dismiss();
                        confirmAndRun(host, targets, spec);
                    }
                });
            }
        });
        dialog.show();
        UiKit.tintDialog(dialog);
    }

    private static int parseInt(String s, int fallback) {
        try {
            int v = Integer.parseInt(s.trim());
            return v > 0 ? v : fallback;
        } catch (Exception e) {
            return fallback;
        }
    }

    private static void confirmAndRun(final MainActivity host, final List<VFile> targets,
                                      final BatchEdit.Spec spec) {
        host.confirm("确认批量编辑",
                "将修改 " + targets.size() + " 首：\n\n" + spec.summary()
                        + "\n\n未勾选的字段保持不变；这一步可以整批撤销。",
                new Runnable() {
                    @Override
                    public void run() {
                        startWrite(host, targets, spec);
                    }
                });
    }

    private static void startWrite(final MainActivity host, final List<VFile> targets,
                            final BatchEdit.Spec spec) {
        host.runTask("批量编辑", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                com.dsh.musicorganizer.core.Storage st = host.safeStorage();
                String batchId = "edit-" + System.currentTimeMillis();
                int ok = 0;
                List<String> errors = new ArrayList<String>();
                for (int i = 0; i < targets.size(); i++) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    VFile f = targets.get(i);
                    host.progressCallback().onProgress(i + 1, targets.size(), f.name);
                    Map<String, String> updates = BatchEdit.updatesFor(spec, i);
                    String err = TagTransaction.apply(st, host.getContentResolver(), host,
                            f, updates, true, batchId, host);
                    if (err.isEmpty()) {
                        ok++;
                    } else {
                        errors.add(f.name + "：" + err);
                    }
                }
                return new Object[]{Integer.valueOf(ok), errors};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                Object[] arr = (Object[]) result;
                int ok = ((Integer) arr[0]).intValue();
                @SuppressWarnings("unchecked")
                List<String> errors = (List<String>) arr[1];
                int failed = errors.size();
                host.log("批量编辑：成功 " + ok + "，失败 " + failed,
                        failed > 0 ? "warning" : "success");
                for (int i = 0; i < errors.size() && i < 8; i++) {
                    host.log("  " + errors.get(i), "warning");
                }
                host.toast("批量编辑完成：成功 " + ok + " 首"
                        + (failed > 0 ? "，失败 " + failed + " 首" : ""));
                host.refreshBrowseTagOnly();
            }
        });
    }
}
