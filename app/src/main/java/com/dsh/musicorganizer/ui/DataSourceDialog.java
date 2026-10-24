package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.DialogInterface;
import android.text.InputType;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;

import com.dsh.musicorganizer.net.Endpoints;

import java.util.ArrayList;
import java.util.List;

/**
 * 数据源设置 —— 地址不写死在代码里，用户在这里改。
 *
 * <p>为什么需要：国内几家音乐站的匿名接口换得勤（路径改名、域名切 CDN、老地址直接 500/405）。
 * 有了这层，接口一变用户自己改个地址就能继续用，不必等下个版本；某家长期不可用也可以直接关掉，
 * 免得每首歌都陪它等一次超时。
 */
public final class DataSourceDialog {

    private DataSourceDialog() {
    }

    public static void show(final MainActivity host) {
        final Endpoints.Config cfg = Endpoints.configOrNull();
        if (cfg == null) {
            host.toast("设置尚未就绪，请稍后重试");
            return;
        }

        final Endpoints.Source[] sources = Endpoints.SOURCES;
        final String[] labels = new String[sources.length];
        final boolean[] checked = new boolean[sources.length];
        int custom = 0;
        for (int i = 0; i < sources.length; i++) {
            Endpoints.Source s = sources[i];
            StringBuilder sb = new StringBuilder();
            sb.append(s.label).append("（").append(s.group).append("）");
            sb.append("\n    ").append(Endpoints.url(s.key, 0));
            boolean changed = false;
            for (int k = 0; k < s.count(); k++) {
                if (Endpoints.customized(s.endpointKey(k))) {
                    changed = true;
                }
            }
            if (changed) {
                sb.append("　· 已修改");
                custom++;
            }
            if (s.count() > 1) {
                sb.append("\n    共 ").append(s.count()).append(" 个接口");
            }
            labels[i] = sb.toString();
            checked[i] = Endpoints.enabled(s.key);
        }

        String message = "勾选＝启用；取消勾选后不再向该站发请求。\n"
                + "「修改地址」可单独改某个接口（某家失效时用），「恢复默认」改回官方地址。"
                + (custom > 0 ? "\n当前有 " + custom + " 个源用了自定义地址。" : "");

        AlertDialog dialog = new UiKit.Builder(host)
                .setTitle("数据源设置")
                .setMessage(message)
                .setMultiChoiceItems(labels, checked,
                        new DialogInterface.OnMultiChoiceClickListener() {
                            @Override
                            public void onClick(DialogInterface d, int which, boolean isChecked) {
                                cfg.setEnabled(sources[which].key, isChecked);
                                host.log("数据源「" + sources[which].label + "」已"
                                        + (isChecked ? "启用" : "停用"), "info");
                            }
                        })
                .setPositiveButton("完成", null)
                .setNeutralButton("修改地址", null)
                .setNegativeButton("恢复默认", null)
                .create();
        dialog.show();
        UiKit.tintDialog(dialog);

        Button neutral = dialog.getButton(AlertDialog.BUTTON_NEUTRAL);
        if (neutral != null) {
            neutral.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    dialog.dismiss();
                    pickEndpoint(host);
                }
            });
        }
        Button negative = dialog.getButton(AlertDialog.BUTTON_NEGATIVE);
        if (negative != null) {
            negative.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    dialog.dismiss();
                    confirmReset(host, cfg);
                }
            });
        }
    }

    /** 第二步：选要改哪个接口。 */
    private static void pickEndpoint(final MainActivity host) {
        final List<String> keys = new ArrayList<String>();
        final List<String> rows = new ArrayList<String>();
        for (Endpoints.Source s : Endpoints.SOURCES) {
            for (int i = 0; i < s.count(); i++) {
                String key = s.endpointKey(i);
                keys.add(key);
                StringBuilder sb = new StringBuilder();
                sb.append(s.label);
                if (s.count() > 1) {
                    sb.append(" · ").append(s.name(i));
                }
                sb.append("\n    ").append(Endpoints.url(key));
                if (Endpoints.customized(key)) {
                    sb.append("　· 已修改");
                }
                rows.add(sb.toString());
            }
        }
        new UiKit.Builder(host)
                .setTitle("选择要修改的接口")
                .setItems(rows.toArray(new String[rows.size()]),
                        new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface d, int which) {
                                editUrl(host, keys.get(which));
                            }
                        })
                .setNegativeButton("返回", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        show(host);
                    }
                })
                .show();
    }

    /** 第三步：编辑地址。留空 = 恢复该接口的默认地址。 */
    private static void editUrl(final MainActivity host, final String endpointKey) {
        final Endpoints.Config cfg = Endpoints.configOrNull();
        if (cfg == null) {
            return;
        }
        LinearLayout box = UiKit.vertical(host);
        int pad = UiKit.dp(host, 16);
        box.setPadding(pad, pad, pad, pad);
        box.addView(UiKit.caption(host, "默认地址：" + Endpoints.defaultUrl(endpointKey)));
        final EditText input = UiKit.input(host, "https://…");
        input.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
        input.setText(Endpoints.url(endpointKey));
        UiKit.margin(input, 0, 8, 0, 0);
        box.addView(input);
        box.addView(UiKit.caption(host,
                "只接受 http:// 或 https:// 开头的地址；留空保存＝恢复默认。"));

        new UiKit.Builder(host)
                .setTitle("修改接口地址")
                .setView(box)
                .setPositiveButton("保存", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        String url = input.getText().toString().trim();
                        if (url.isEmpty()) {
                            cfg.setOverride(endpointKey, null);
                            host.log("接口已恢复默认：" + endpointKey, "info");
                            host.toast("已恢复默认地址");
                            show(host);
                            return;
                        }
                        if (!Endpoints.isValidUrl(url)) {
                            host.toast("地址不合法：需要 http:// 或 https:// 开头，且不能有空格");
                            editUrl(host, endpointKey);
                            return;
                        }
                        cfg.setOverride(endpointKey, url);
                        host.log("接口地址已更新：" + endpointKey + " → " + url, "info");
                        host.toast("已保存");
                        show(host);
                    }
                })
                .setNegativeButton("取消", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        show(host);
                    }
                })
                .show();
    }

    private static void confirmReset(final MainActivity host, final Endpoints.Config cfg) {
        new UiKit.Builder(host)
                .setTitle("恢复默认地址？")
                .setMessage("所有改过的接口地址都会恢复成官方地址（启用/停用状态不变）。")
                .setPositiveButton("恢复", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        Endpoints.resetAll();
                        host.log("所有接口地址已恢复默认", "info");
                        host.toast("已恢复默认地址");
                        show(host);
                    }
                })
                .setNegativeButton("取消", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        show(host);
                    }
                })
                .show();
    }
}
