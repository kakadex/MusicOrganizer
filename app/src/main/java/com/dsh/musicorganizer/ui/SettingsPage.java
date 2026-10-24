package com.dsh.musicorganizer.ui;

import android.content.Context;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.ScrollView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.AppUpdate;
import com.dsh.musicorganizer.core.Layout;
import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.core.SettingsBackup;
import com.dsh.musicorganizer.core.TagFill;
import com.dsh.musicorganizer.core.Theme;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 设置页（独立页签）：主题 / 整理选项 / 批量写入策略 / 在线匹配权重 / 数据源 /
 * 字段写入策略 / 设置备份 / 运行日志 / 关于。
 *
 * <p>这些项原本混在「整理」页的各个卡片里（数据源在权重卡、字段策略在标签卡、备份与
 * 记忆在安全网卡、主题与更新在关于卡），v0.1.20 起统一收进本页，整理页只留实际操作。
 */
public final class SettingsPage extends ScrollView {

    private final MainActivity host;
    private TextView updateStatus;

    public SettingsPage(MainActivity host) {
        super(host);
        this.host = host;
        try {
            build();
        } catch (Throwable t) {
            // 设置页只是次要功能：构建失败也要让应用能起来，把错误直接摊在页面上
            // （否则一个空指针就能让整个应用在启动时崩掉 —— v0.1.20 的教训）
            showFallback(t);
        }
    }


    /** 构建失败时的兜底页：显示异常摘要，其余功能照常可用。 */
    private void showFallback(Throwable t) {
        int pad = UiKit.dp(getContext(), 16);
        setPadding(pad, pad, pad, pad);
        LinearLayout box = UiKit.vertical(getContext());
        TextView title = UiKit.text(getContext(), "设置页加载失败", 16, UiKit.errColor(), true);
        box.addView(title);
        box.addView(UiKit.caption(getContext(),
                "这不影响整理 / 库 / 日志三个页签。把下面这段发给开发者即可定位："));
        TextView detail = UiKit.caption(getContext(), android.util.Log.getStackTraceString(t));
        box.addView(detail);
        addView(box);
        android.util.Log.e("MusicOrganizer", "SettingsPage build failed", t);
    }

    private void build() {
        Context ctx = getContext();
        LinearLayout root = UiKit.vertical(ctx);
        int pad = UiKit.dp(ctx, 16);
        setPadding(pad, pad, pad, pad);
        setFillViewport(true);

        // ---- 文件夹管理：点进去是文件夹列表----
        LinearLayout cardDir = UiKit.card(ctx);
        cardDir.addView(UiKit.text(ctx, "文件夹管理", 16, UiKit.textColor(), true));
        cardDir.addView(UiKit.caption(ctx, "当前：" + host.repo.treeDisplayName()));
        Button btnDir = UiKit.button(ctx, "管理文件夹", true);
        btnDir.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                FolderManagerDialog.show(host);
            }
        });
        UiKit.margin(btnDir, 0, 8, 0, 0);
        cardDir.addView(btnDir);
        cardDir.addView(UiKit.caption(ctx,
                "列出已授权的音乐文件夹，可添加 / 更换 / 移除；选好后自动扫描并显示列表。"));
        root.addView(cardDir);

        // ---- 主题 ----
        LinearLayout cardTheme = UiKit.card(ctx);
        cardTheme.addView(UiKit.text(ctx, "主题", 16, UiKit.textColor(), true));
        LinearLayout themeRow = UiKit.horizontal(ctx);
        for (int i = 0; i < Theme.NAMES.length; i++) {
            final int themeId = i;
            TextView chip = UiKit.chip(ctx, Theme.NAMES[i], UiKit.themeId() == themeId);
            chip.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    if (UiKit.themeId() == themeId) {
                        return;
                    }
                    host.repo.setInt("theme_id", themeId);
                    host.log("主题切换：" + Theme.name(themeId), "info");
                    host.recreate();
                }
            });
            LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            if (i > 0) {
                tlp.setMargins(UiKit.dp(ctx, 6), 0, 0, 0);
            }
            themeRow.addView(chip, tlp);
        }
        UiKit.margin(themeRow, 0, 4, 0, 0);
        cardTheme.addView(themeRow);
        final CheckBox cbDark = UiKit.checkbox(ctx, "夜间模式", UiKit.isDark());
        cbDark.setOnCheckedChangeListener(new android.widget.CompoundButton.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(android.widget.CompoundButton b, boolean checked) {
                host.repo.setBool("theme_dark", checked);
                host.log("夜间模式：" + (checked ? "开" : "关"), "info");
                host.recreate();
            }
        });
        cardTheme.addView(cbDark);
        cardTheme.addView(UiKit.caption(ctx,
                "三种配色各有亮色 / 暗色两套，切换后立即生效并记住。"));
        UiKit.margin(cardTheme, 0, 12, 0, 0);
        root.addView(cardTheme);

        // ---- 工具：整理工具（其选项在下方，v0.1.72 起按用户要求归到这里）----
        LinearLayout cardTools = UiKit.card(ctx);
        UiKit.margin(cardTools, 0, 12, 0, 0);
        cardTools.addView(UiKit.text(ctx, "工具", 16, UiKit.textColor(), true));
        cardTools.addView(UiKit.caption(ctx,
                "主界面只保留「音乐库」；扫描、清理、批量标签等整理操作从这里进入。"));
        Button btnOrganize = UiKit.button(ctx, "整理工具", false);
        btnOrganize.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                host.openOrganizeTab();
            }
        });
        UiKit.margin(btnOrganize, 0, 8, 0, 0);
        cardTools.addView(btnOrganize);
        cardTools.addView(UiKit.caption(ctx,
                "整理工具内含全部参数：整理选项 / 批量写入策略 / 字段写入策略 / 数据源。"));

        // 文件名查重 / 重复文件（v0.1.74 起从音乐库页的筛选条移到这里，主界面只留筛选）
        LinearLayout rowDedup = UiKit.horizontal(ctx);
        Button btnDupName = UiKit.button(ctx, "文件名查重", false);
        btnDupName.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                // 不切页：结果对话框直接盖在设置页上
                host.runFileNameDedup();
            }
        });
        Button btnDupContent = UiKit.button(ctx, "重复文件", false);
        btnDupContent.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                DupFilesDialog.show(host);
            }
        });
        rowDedup.addView(btnDupName, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        LinearLayout.LayoutParams pDup = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        pDup.setMargins(UiKit.dp(ctx, 8), 0, 0, 0);
        rowDedup.addView(btnDupContent, pDup);
        UiKit.margin(rowDedup, 0, 8, 0, 0);
        cardTools.addView(rowDedup);
        cardTools.addView(UiKit.caption(ctx,
                "文件名查重：按文件名相似度 ≥90% 分组；重复文件：按内容（大小 + 头部 64KB）比对，"
                        + "保留一份、删掉多余的。"));
        root.addView(cardTools);

        // ---- 设置备份 ----
        LinearLayout cardBackup = UiKit.card(ctx);
        UiKit.margin(cardBackup, 0, 12, 0, 0);
        cardBackup.addView(UiKit.text(ctx, "设置备份", 16, UiKit.textColor(), true));
        cardBackup.addView(UiKit.caption(ctx,
                "把权重、字段策略、数据源地址与各开关导出成 JSON，换机或重装后导入即可还原"
                        + "（目录授权属于本机，不导出）。"));
        LinearLayout rowBackup = UiKit.horizontal(ctx);
        Button btnExportSet = UiKit.button(ctx, "导出设置", false);
        Button btnImportSet = UiKit.button(ctx, "导入设置", false);
        btnExportSet.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                host.exportSettings();
            }
        });
        btnImportSet.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                host.importSettings();
            }
        });
        rowBackup.addView(btnExportSet, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        LinearLayout.LayoutParams pBackup = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        pBackup.setMargins(UiKit.dp(ctx, 8), 0, 0, 0);
        rowBackup.addView(btnImportSet, pBackup);
        UiKit.margin(rowBackup, 0, 8, 0, 0);
        cardBackup.addView(rowBackup);
        Button btnCsv = UiKit.button(ctx, "导出曲库清单（CSV）", false);
        UiKit.margin(btnCsv, 0, 8, 0, 0);
        btnCsv.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                host.exportLibraryCsv();
            }
        });
        cardBackup.addView(btnCsv);
        Button btnClearMemory = UiKit.button(ctx, "清除增量匹配记忆", false);
        UiKit.margin(btnClearMemory, 0, 8, 0, 0);
        btnClearMemory.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                clearBatchMemory();
            }
        });
        cardBackup.addView(btnClearMemory);
        Button btnReset = UiKit.button(ctx, "恢复默认设置", false);
        UiKit.margin(btnReset, 0, 8, 0, 0);
        btnReset.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                restoreDefaults();
            }
        });
        cardBackup.addView(btnReset);
        root.addView(cardBackup);

        // ---- 运行日志（单独一项，v0.1.72）----
        LinearLayout cardLog = UiKit.card(ctx);
        UiKit.margin(cardLog, 0, 12, 0, 0);
        cardLog.addView(UiKit.text(ctx, "运行日志", 16, UiKit.textColor(), true));
        cardLog.addView(UiKit.caption(ctx,
                "查看 / 导出本次运行的详细记录，排查问题时用（扫描、写入、错误都会记）。"));
        Button btnLog = UiKit.button(ctx, "查看运行日志", false);
        UiKit.margin(btnLog, 0, 8, 0, 0);
        btnLog.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                host.openLogTab();
            }
        });
        cardLog.addView(btnLog);
        root.addView(cardLog);

        // ---- 关于（应用信息 / 项目地址 / 反馈 / 开源许可 / 更新）----
        LinearLayout cardAbout = UiKit.card(ctx);
        UiKit.margin(cardAbout, 0, 12, 0, 0);
        cardAbout.addView(UiKit.text(ctx, "关于", 16, UiKit.textColor(), true));
        cardAbout.addView(UiKit.caption(ctx,
                "音乐整理工具 v" + host.versionName() + "（build " + host.versionCode() + "）\n"
                        + "MIT 开源 · 零第三方依赖 · 纯本地处理"));

        Button btnRepoPage = UiKit.button(ctx, "项目地址（Gitee）", false);
        btnRepoPage.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                UpdateDialog.open(host, com.dsh.musicorganizer.net.UpdateClient.repoPage());
            }
        });
        UiKit.margin(btnRepoPage, 0, 10, 0, 0);
        cardAbout.addView(btnRepoPage);

        Button btnFeedback = UiKit.button(ctx, "问题反馈", false);
        btnFeedback.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                UpdateDialog.open(host,
                        com.dsh.musicorganizer.net.UpdateClient.repoPage() + "/issues");
            }
        });
        UiKit.margin(btnFeedback, 0, 8, 0, 0);
        cardAbout.addView(btnFeedback);

        Button btnLicense = UiKit.button(ctx, "开源许可（MIT）", false);
        btnLicense.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                new UiKit.Builder(host)
                        .setTitle("开源许可（MIT）")
                        .setMessage("本应用以 MIT 许可证开源。\n\n"
                                + "可自由使用、修改、分发，但需保留版权声明与许可声明；"
                                + "软件按「现状」提供，不附带任何担保。")
                        .setPositiveButton("知道了", null)
                        .show();
            }
        });
        UiKit.margin(btnLicense, 0, 8, 0, 0);
        cardAbout.addView(btnLicense);

        Button btnCheckUpdate = UiKit.button(ctx, "检查更新", true);
        btnCheckUpdate.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                UpdateDialog.show(host, new Runnable() {
                    @Override
                    public void run() {
                        refreshUpdateStatus();
                        host.refreshUpdateHint();
                    }
                });
            }
        });
        UiKit.margin(btnCheckUpdate, 0, 10, 0, 0);
        cardAbout.addView(btnCheckUpdate);

        updateStatus = UiKit.caption(ctx, "");
        UiKit.margin(updateStatus, 0, 8, 0, 0);
        cardAbout.addView(updateStatus);

        final CheckBox cbAutoUpdate = UiKit.checkbox(ctx,
                "启动时检查更新（每天最多一次）", host.repo.bool(Repo.KEY_UPDATE_AUTO, true));
        cbAutoUpdate.setOnCheckedChangeListener(new android.widget.CompoundButton.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(android.widget.CompoundButton b, boolean checked) {
                host.repo.setBool(Repo.KEY_UPDATE_AUTO, checked);
                host.log("启动时检查更新：" + (checked ? "开" : "关"), "info");
            }
        });
        cardAbout.addView(cbAutoUpdate);
        cardAbout.addView(UiKit.caption(ctx,
                "国内优先查 Gitee、GitHub 兜底；只读版本信息（不改动任何文件），下载走浏览器，安装由系统确认。"));
        root.addView(cardAbout);

        addView(root);
        refreshUpdateStatus();
    }

    /**
     * 恢复默认设置（v0.1.36）：只还原偏好，不动目录授权 / 扫描结果 / 写入历史。
     * 先算「哪些项不是默认值」，在确认框里说清楚再动手。
     */
    private void restoreDefaults() {
        Map<String, Object> current = new LinkedHashMap<String, Object>();
        for (Map.Entry<String, Object> e : SettingsBackup.defaults().entrySet()) {
            Object v = e.getValue();
            if (v instanceof Integer) {
                current.put(e.getKey(), Integer.valueOf(
                        host.repo.intVal(e.getKey(), ((Integer) v).intValue())));
            } else {
                current.put(e.getKey(), Boolean.valueOf(
                        host.repo.bool(e.getKey(), Boolean.TRUE.equals(v))));
            }
        }
        final List<String> diff = SettingsBackup.diffFromDefaults(current);
        String msg = diff.isEmpty()
                ? "当前所有设置都已是默认值。仍要清一遍吗？（目录授权、扫描结果、写入历史都不会动）"
                : "有 " + diff.size() + " 项不是默认值：\n" + describe(diff)
                + "\n恢复后这些项回到出厂状态；目录授权、扫描结果、写入历史、日志都不受影响。";
        new UiKit.Builder(host)
                .setTitle("恢复默认设置")
                .setMessage(msg)
                .setNegativeButton("取消", null)
                .setPositiveButton("恢复", new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface d, int which) {
                        int n = host.repo.resetSettings();
                        host.log("已恢复默认设置：清掉 " + n + " 项偏好", "success");
                        host.toast(n > 0 ? "已恢复 " + n + " 项默认设置" : "没有需要恢复的设置");
                        host.recreate();
                    }
                })
                .show();
    }

    /** 把键名翻成人话，最多列 6 项。 */
    private static String describe(List<String> keys) {
        StringBuilder sb = new StringBuilder();
        int n = 0;
        for (String k : keys) {
            if (n >= 6) {
                sb.append("…等 ").append(keys.size()).append(" 项");
                break;
            }
            sb.append("· ").append(label(k)).append('\n');
            n++;
        }
        return sb.toString().trim();
    }

    private static String label(String key) {
        if (SettingsBackup.KEY_WEIGHT.equals(key)) {
            return "文件名权重";
        }
        if (SettingsBackup.KEY_THEME_ID.equals(key)) {
            return "主题";
        }
        if (SettingsBackup.KEY_LAYOUT.equals(key)) {
            return "整理目录结构";
        }
        if (key.startsWith(SettingsBackup.PREFIX_FIELD_MODE)) {
            return "字段策略：" + key.substring(SettingsBackup.PREFIX_FIELD_MODE.length());
        }
        if (key.startsWith(SettingsBackup.PREFIX_ENDPOINT)) {
            return "接口地址：" + key.substring(SettingsBackup.PREFIX_ENDPOINT.length());
        }
        if (key.startsWith(SettingsBackup.PREFIX_SOURCE_ON)) {
            return "数据源开关：" + key.substring(SettingsBackup.PREFIX_SOURCE_ON.length());
        }
        return key;
    }

    private void clearBatchMemory() {
        final com.dsh.musicorganizer.core.BatchMemory tags = host.batchMemory("tags");
        final com.dsh.musicorganizer.core.BatchMemory lyrics = host.batchMemory("lyrics");
        final com.dsh.musicorganizer.core.BatchMemory cover = host.batchMemory("cover");
        host.confirm("清除增量匹配记忆",
                "当前记忆：\n· 标签：" + tags.summary() + "\n· 歌词：" + lyrics.summary()
                        + "\n· 封面：" + cover.summary()
                        + "\n\n清除后下一批会把所有歌重新查一遍。"
                        + "\n只想重查某几首的话，在库页选中它们点「改标签」，"
                        + "弹窗里选「重新查询这 N 首」即可，不用清空全部记忆。",
                new Runnable() {
                    @Override
                    public void run() {
                        tags.delete();
                        lyrics.delete();
                        cover.delete();
                        host.toast("已清除匹配记忆");
                        host.log("已清除增量匹配记忆（标签/歌词/封面）", "info");
                    }
                });
    }

    /** 刷新「关于」里的状态行（检查完、切到本页时都要调）。 */
    public void refreshUpdateStatus() {
        if (updateStatus == null) {
            return;
        }
        String tag = host.repo.str(Repo.KEY_UPDATE_TAG, "");
        boolean newer = !tag.isEmpty() && AppUpdate.isNewer(host.versionName(), tag);
        StringBuilder sb = new StringBuilder(UpdateDialog.lastCheckSummary(host.repo));
        if (newer) {
            sb.append("\n发现新版本 ").append(AppUpdate.display(tag))
                    .append("，点「检查更新」看说明并下载");
            updateStatus.setTextColor(UiKit.errColor());
        } else {
            updateStatus.setTextColor(UiKit.subColor());
        }
        if (UpdateDialog.disabled()) {
            sb.append("\n两个更新源都已停用，检查会直接失败（数据源设置里可重新启用）");
        }
        updateStatus.setText(sb.toString());
    }
}
