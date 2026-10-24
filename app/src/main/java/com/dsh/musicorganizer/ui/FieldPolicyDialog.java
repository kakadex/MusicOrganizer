package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.DialogInterface;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.dsh.musicorganizer.core.TagFill;

import java.util.Map;

/**
 * 字段写入策略对话框 —— 每个标签字段单独设「不写 / 只补空 / 覆盖」，
 * 未单独设置的字段跟随「覆盖已有标签」开关（第一档③）。
 *
 * <p>点字段名旁边的按钮循环切换三态：不写 → 只补空 → 覆盖。
 * 「清空自定义」把所有字段恢复为跟随全局开关。
 */
public final class FieldPolicyDialog {

    private FieldPolicyDialog() {
    }

    public interface OnChanged {
        void changed();
    }

    public static void show(final MainActivity host, final Map<String, Integer> currentModes,
                            final OnChanged onChanged) {
        final String[] fields = TagFill.CANDIDATE_FIELDS;
        final int[] modes = new int[fields.length];
        for (int i = 0; i < fields.length; i++) {
            modes[i] = TagFill.modeOf(currentModes, fields[i]);
        }

        LinearLayout panel = UiKit.vertical(host);
        panel.addView(UiKit.caption(host,
                "每个字段单独设「不写 / 只补空 / 覆盖」；未单独设置的字段跟随「覆盖已有标签」开关。"));

        final Button[] buttons = new Button[fields.length];
        for (int i = 0; i < fields.length; i++) {
            final int idx = i;
            LinearLayout row = UiKit.horizontal(host);
            TextView name = UiKit.text(host, TagFill.label(fields[i]), 15, UiKit.textColor(), true);
            name.setLayoutParams(new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            Button b = UiKit.button(host, TagFill.modeName(modes[i]), false);
            b.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    modes[idx] = (modes[idx] + 1) % 3;
                    buttons[idx].setText(TagFill.modeName(modes[idx]));
                }
            });
            buttons[i] = b;
            row.addView(name);
            row.addView(b);
            panel.addView(row);
        }

        AlertDialog dialog = new UiKit.Builder(host)
                .setTitle("字段写入策略")
                .setView(panel)
                .setNeutralButton("清空自定义", null)
                .setNegativeButton("取消", null)
                .setPositiveButton("确定", null)
                .create();
        dialog.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override
            public void onShow(DialogInterface d) {
                // 清空自定义：删除所有 fp: 键，恢复跟随全局开关
                dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(
                        new View.OnClickListener() {
                            @Override
                            public void onClick(View v) {
                                host.repo.clearTagFieldModes();
                                onChanged.changed();
                                dialog.dismiss();
                            }
                        });
                // 确定：把当前六项显式保存
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(
                        new View.OnClickListener() {
                            @Override
                            public void onClick(View v) {
                                for (int i = 0; i < fields.length; i++) {
                                    host.repo.setTagFieldMode(fields[i], modes[i]);
                                }
                                onChanged.changed();
                                dialog.dismiss();
                            }
                        });
            }
        });
        dialog.show();
        UiKit.tintDialog(dialog);
    }
}
