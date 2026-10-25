package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

import com.dsh.musicorganizer.core.AppUpdate;
import com.dsh.musicorganizer.core.Theme;
import com.dsh.musicorganizer.core.Cleaner;
import com.dsh.musicorganizer.core.Layout;
import com.dsh.musicorganizer.core.Lyrics;
import com.dsh.musicorganizer.core.MoveJournal;
import com.dsh.musicorganizer.core.MoveLog;
import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.core.Organizer;
import com.dsh.musicorganizer.core.PartialSink;
import com.dsh.musicorganizer.core.Progress;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.TagBatch;
import com.dsh.musicorganizer.core.TagFill;
import com.dsh.musicorganizer.core.TagTransaction;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.TrackGroup;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** 整理页：扫描 / 自动整理 / 清理 / 歌词 / 撤销。 */
public final class OrganizePage extends ScrollView {

    private final MainActivity host;

    private TextView scanSummary;

    /** 扫描完成后是否自动触发整理（「自动整理」按钮 = 扫描 + 整理，v0.1.99）。 */
    private boolean pendingAutoOrganize = false;

    public OrganizePage(MainActivity host) {
        super(host);
        this.host = host;
        build();
    }

    private void build() {
        Context ctx = getContext();
        LinearLayout root = UiKit.vertical(ctx);
        int pad = UiKit.dp(ctx, 16);
        setPadding(pad, pad, pad, pad);
        setFillViewport(true);

        LinearLayout.LayoutParams lp1 = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        LinearLayout.LayoutParams p2 = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        p2.setMargins(UiKit.dp(ctx, 8), 0, 0, 0);

        // ---- ① 自动整理（扫描统计 + 自动整理 合并为一个按钮）----
        UiKit.Section secScan = UiKit.collapsibleCard(ctx, "① 自动整理",
                !host.repo.bool("org_scan", false));
        LinearLayout body = secScan.body;
        body.addView(UiKit.caption(ctx,
                "点「自动整理」即先扫描再按所选目录结构归位（音频 + 歌词成组）；"
                        + "识别失败的组默认「保留原位」。"));
        // 系统媒体库（v0.1.42）：SAF 选不到的目录（如「下载」）靠它列出来
        Button btnMedia = UiKit.button(ctx, "系统媒体库（含下载目录）", false);
        btnMedia.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                host.openMediaLibrary();
            }
        });
        UiKit.margin(btnMedia, 0, 8, 0, 0);
        body.addView(btnMedia);
        body.addView(UiKit.caption(ctx,
                "系统媒体库能看到「下载」这类手动授权不了的目录；勾选后复制到当前目录，"
                        + "之后再走标签 / 歌词 / 整理。第一次用需要给一次读取音频的权限。"));

        Button btnOrganize = UiKit.button(ctx, "自动整理", true);
        UiKit.margin(btnOrganize, 0, 8, 0, 0);
        btnOrganize.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                autoOrganize();
            }
        });
        body.addView(btnOrganize);
        scanSummary = UiKit.caption(ctx, "尚未扫描");
        UiKit.margin(scanSummary, 0, 6, 0, 0);
        body.addView(scanSummary);

        // 整理选项（艺人 / 专辑）+ 设置入口，内联进自动整理卡片（v0.1.99）
        body.addView(new OrganizeOptionsPanel(host));
        bindCollapse(secScan, "org_scan");
        root.addView(secScan.root);

        // ---- ② 文件名清理 ----
        UiKit.Section secClean = UiKit.collapsibleCard(ctx, "② 文件名清理",
                !host.repo.bool("org_clean", false));
        UiKit.margin(secClean.root, 0, 12, 0, 0);
        body = secClean.body;
        body.addView(UiKit.caption(ctx,
                "去 _N 污染后缀 / 重编码标记；中文文件名去空格；可同时删除空目录。"));
        LinearLayout row2 = UiKit.horizontal(ctx);
        Button btnPreviewClean = UiKit.button(ctx, "预览清理", false);
        Button btnClean = UiKit.button(ctx, "执行清理", true);
        btnPreviewClean.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                runCleanup(true);
            }
        });
        btnClean.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                runCleanup(false);
            }
        });
        row2.addView(btnPreviewClean, lp1);
        row2.addView(btnClean, p2);
        body.addView(row2);
        Button btnEmptyDirs = UiKit.button(ctx, "删除空子文件夹（未识别 受保护）", false);
        UiKit.margin(btnEmptyDirs, 0, 8, 0, 0);
        btnEmptyDirs.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                deleteEmptyDirs();
            }
        });
        body.addView(btnEmptyDirs);
        // 查重：按内容（大小 + 头尾各 64KB）比对，找出重复文件，勾选后删除
        Button btnDup = UiKit.button(ctx, "查重（重复文件）", false);
        UiKit.margin(btnDup, 0, 8, 0, 0);
        btnDup.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                DupFilesDialog.show(host);
            }
        });
        body.addView(btnDup);
        body.addView(UiKit.caption(ctx,
                "按内容（大小 + 头尾各 64KB）比对，找出重复文件，勾选后删除。"));
        // 扁平化：Windows 版一直有的功能，把嵌套子文件夹里的文件全部拉到当前这一层
        Button btnFlatten = UiKit.button(ctx, "扁平化文件夹（子文件夹 → 当前目录）", false);
        UiKit.margin(btnFlatten, 0, 8, 0, 0);
        btnFlatten.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                flatten();
            }
        });
        body.addView(btnFlatten);
        body.addView(UiKit.caption(ctx,
                "把子文件夹里的音频 / 歌词全部移到当前目录这一层，撞名自动加 _2 / _3 序号，"
                        + "移动后删除空出来的子文件夹。先预览移动清单再执行。"));
        // 垃圾文件（v0.1.38）：0 字节、.lrc.bak、临时文件、系统垃圾
        Button btnJunk = UiKit.button(ctx, "清理垃圾文件", false);
        UiKit.margin(btnJunk, 0, 8, 0, 0);
        btnJunk.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                JunkDialog.show(host);
            }
        });
        body.addView(btnJunk);
        body.addView(UiKit.caption(ctx,
                "按扫描结果挑出 0 字节文件、.lrc.bak 歌词备份、未完成的临时文件与 "
                        + "Thumbs.db/.DS_Store 这类系统垃圾，勾选后再删。"));
        bindCollapse(secClean, "org_clean");
        root.addView(secClean.root);

        // ---- ③ 批量在线标签 ----
        UiKit.Section secTag = UiKit.collapsibleCard(ctx, "③ 批量在线标签",
                !host.repo.bool("org_tag", false));
        UiKit.margin(secTag.root, 0, 12, 0, 0);
        body = secTag.body;
        body.addView(UiKit.caption(ctx,
                "多源聚合（MusicBrainz / Deezer / iTunes + 网易 / QQ / 酷狗 / 酷我 / 咪咕），"
                        + "只处理 MP3 与 FLAC；先匹配出预览，勾选确认后才写入。"));
        Button btnTag = UiKit.button(ctx, "批量获取标签", true);
        btnTag.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                fetchTags();
            }
        });
        body.addView(btnTag);
        // 封面：与标签同一批源，但写的是二进制块，所以单独一条链路（替换不可撤销）
        body.addView(UiKit.caption(ctx,
                "专辑封面：从同一批在线源（Deezer / iTunes / 网易 / QQ）取专辑图写入标签，"
                        + "先预览勾选，再下载写入。"));
        Button btnCover = UiKit.button(ctx, "批量补封面", false);
        btnCover.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                fetchCovers();
            }
        });
        body.addView(btnCover);
        bindCollapse(secTag, "org_tag");
        root.addView(secTag.root);

        // ---- ④ 批量歌词 ----
        UiKit.Section secLrc = UiKit.collapsibleCard(ctx, "④ 批量歌词（LRCLIB）",
                !host.repo.bool("org_lrc", false));
        UiKit.margin(secLrc.root, 0, 12, 0, 0);
        body = secLrc.body;
        body.addView(UiKit.caption(ctx, "为音频写入同名 .lrc；无 Key、质量校验、覆盖前备份。"));
        Button btnLrc = UiKit.button(ctx, "批量获取歌词", true);
        btnLrc.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                fetchLyrics();
            }
        });
        body.addView(btnLrc);
        bindCollapse(secLrc, "org_lrc");
        root.addView(secLrc.root);

        // ---- ⑤ 安全网 ----
        UiKit.Section secUndo = UiKit.collapsibleCard(ctx, "⑤ 安全网",
                !host.repo.bool("org_undo", false));
        UiKit.margin(secUndo.root, 0, 12, 0, 0);
        body = secUndo.body;
        body.addView(UiKit.caption(ctx,
                "标签写入全部走事务层；批量写入共用批次号，撤销时整批回滚。"));
        Button btnRevert = UiKit.button(ctx, "撤销最近一次标签写入（整批）", false);
        btnRevert.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                revertLast();
            }
        });
        body.addView(btnRevert);
        Button btnHistory = UiKit.button(ctx, "撤销历史（标签写入 / 整理移动）", false);
        btnHistory.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                HistoryDialog.show(host);
            }
        });
        UiKit.margin(btnHistory, 0, 8, 0, 0);
        body.addView(btnHistory);
        Button btnUndoMove = UiKit.button(ctx, "撤销上次整理（文件搬回原位）", false);
        btnUndoMove.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                revertLastOrganize();
            }
        });
        UiKit.margin(btnUndoMove, 0, 8, 0, 0);
        body.addView(btnUndoMove);
        bindCollapse(secUndo, "org_undo");
        root.addView(secUndo.root);

        addView(root);
    }

    /** 把卡片的折叠状态落盘到偏好（键名固定），重开页面/旋转后保持。 */
    private void bindCollapse(final UiKit.Section s, final String key) {
        s.setOnToggleListener(new Runnable() {
            @Override
            public void run() {
                host.repo.setBool(key, !s.isExpanded());
            }
        });
    }

    public void setScanSummary(String text) {
        scanSummary.setText(text);
    }

    /** 把任务进度同时反映到页面上（之前只进任务中心/通知，页面一动不动）。 */
    private com.dsh.musicorganizer.core.Progress uiProgress() {
        final com.dsh.musicorganizer.core.Progress base = host.progressCallback();
        return new com.dsh.musicorganizer.core.Progress() {
            @Override
            public void onProgress(final int done, final int total, final String message) {
                base.onProgress(done, total, message);
                host.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        setScanSummary((total > 0 ? done + "/" + total + " · " : "") + message);
                    }
                });
            }
        };
    }

    /**
     * 扫描时发现根目录没有音频会自动改递归，这里把开关同步过去（v0.1.50 起设置项
     * 全部收敛到设置页，所以直接写偏好，不再有本地控件可同步）。
     */
    public void setRecursive(boolean on) {
        host.repo.setBool("recursive", on);
    }

    // ------------------------------------------------------------------

    /** 「自动整理」按钮入口：先扫描，扫描完成后自动整理（v0.1.99 合并了「扫描统计」）。 */
    private void autoOrganize() {
        pendingAutoOrganize = true;
        host.scanGroups(false);
    }

    /** 扫描完成后由 MainActivity 调用：若本轮是「自动整理」触发的扫描，返回 true 并清标志。 */
    public boolean consumePendingOrganize() {
        if (!pendingAutoOrganize) {
            return false;
        }
        pendingAutoOrganize = false;
        return true;
    }

    /** 供 MainActivity 在扫描完成后触发整理（organize 为私有，这里给一个公开包装）。 */
    public void doOrganize() {
        organize();
    }

    private void organize() {
        // 用「有没有扫到文件」判断是否扫过，而不是「待归位组是否为空」——
        // 否则「都归位了 / 都在未识别目录」这类「0 组待归位」会被误报成「请先扫描」。
        if (host.repo.lastFiles.isEmpty()) {
            host.toast("没有找到可整理的音频文件");
            return;
        }
        if (host.repo.lastGroups.isEmpty()) {
            com.dsh.musicorganizer.core.ScanStats st = host.repo.lastStats;
            String head = st == null || st.audio <= 0
                    ? "扫描到 " + host.repo.lastFiles.size() + " 个文件"
                    : "扫描到 " + st.audio + " 首音频"
                    + (st.lyrics > 0 ? "（另有 " + st.lyrics + " 个歌词文件）" : "");
            host.message("没有需要整理的",
                    head + "，但没有「待归位」的组。\n\n"
                            + "可能原因：\n"
                            + "· 文件都已经在各自的歌手目录里（已归位）；\n"
                            + "· 文件在「未识别」目录里（识别失败，整理不会动它们）。\n\n"
                            + "可以在「库」页查看具体情况；若确实需要重新分组，"
                            + "在文件页顶部点「扫描」即可。");
            return;
        }
        final boolean dry = host.repo.bool("dry", false);
        final List<TrackGroup> groups = host.repo.lastGroups;
        host.confirm("自动整理", (dry ? "预览模式（不移动任何文件）：" : "")
                + "将处理 " + groups.size() + " 组文件。\n\n"
                + "识别失败的组：" + (host.repo.bool("move_unrec", false)
                        ? "移入「未识别」目录" : "保留原位（不动）") + "\n"
                + "继续？", new Runnable() {
            @Override
            public void run() {
                host.runTask("自动整理", new Tasks.Job() {
                    @Override
                    public Object run() throws Exception {
                        Storage st = host.safeStorage();
                        Organizer.Options o = new Organizer.Options();
                        o.recursive = host.repo.bool("recursive", true);
                        o.skipArtistDirs = host.repo.bool("skip_artist", true);
                        o.fastMode = host.repo.bool("fast", true);
                        o.useNetwork = host.repo.bool("net", true);
                        o.useCnSources = host.repo.bool("cn", true);
                        o.dryRun = dry;
                        o.moveUnrecognized = host.repo.bool("move_unrec", false);
                        o.layout = host.repo.intVal("layout_id", Layout.ARTIST);
                        o.ctx = host;
                        Organizer.Result r = Organizer.organize(st,
                                host.getContentResolver(), host.repo.mb,
                                host.root(), groups, o,
                                host.progressCallback(), host.cancelToken(), host);
                        return r;
                    }
                }, new Tasks.Callback() {
                    @Override
                    public void done(Object result, Exception error) {
                        if (error != null) {
                            host.fail(error);
                            return;
                        }
                        Organizer.Result r = (Organizer.Result) result;
                        String tail = (r.stale > 0 ? "，列表过期跳过 " + r.stale : "");
                        host.log("整理完成：归位 " + r.ok + "，未识别 " + r.unrecognized
                                + "，跳过 " + r.skipped + "，失败 " + r.failed + tail, "success");
                        host.toast("完成：归位 " + r.ok + "，未识别 " + r.unrecognized
                                + "，失败 " + r.failed);
                        host.invalidateScan();
                    }
                });
            }
        });
    }

    private void runCleanup(final boolean preview) {
        host.runTask(preview ? "预览清理" : "文件名清理", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                List<VFile> files = Scanner.walkMusic(st, host.root(),
                        host.repo.bool("recursive", true), host.progressCallback(), host.cancelToken());
                List<Cleaner.RenamePlan> plans = Cleaner.planCleanup(st, files);
                if (preview) {
                    return plans;
                }
                int[] result = Cleaner.execute(plans, host);
                int removed = Cleaner.deleteEmptyDirs(st, host.root(), host.cancelToken());
                return new Object[]{result, removed};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                if (result instanceof List) {
                    @SuppressWarnings("unchecked")
                    List<Cleaner.RenamePlan> plans = (List<Cleaner.RenamePlan>) result;
                    StringBuilder sb = new StringBuilder();
                    int shown = 0;
                    for (Cleaner.RenamePlan p : plans) {
                        if (p.status.equals("ok")) {
                            if (shown < 40) {
                                sb.append(p.source.name).append("  →  ").append(p.targetName()).append('\n');
                            }
                            shown++;
                        }
                    }
                    long count = 0;
                    for (Cleaner.RenamePlan p : plans) {
                        if (p.status.equals("ok")) {
                            count++;
                        }
                    }
                    if (count == 0) {
                        host.toast("没有需要清理的文件名");
                    } else {
                        host.message("预览（" + count + " 项待重命名）",
                                sb.length() > 4000 ? sb.substring(0, 4000) + "…" : sb.toString());
                    }
                } else {
                    Object[] arr = (Object[]) result;
                    int[] r = (int[]) arr[0];
                    host.log("清理完成：重命名 " + r[0] + "，冲突 " + r[1]
                            + "，失败 " + r[2] + "，删除空目录 " + arr[1], "success");
                    host.toast("重命名 " + r[0] + "，失败 " + r[2]
                            + "，删除空目录 " + arr[1]);
                    host.invalidateScan();
                }
            }
        });
    }

    private void deleteEmptyDirs() {
        host.runTask("删除空文件夹", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return Cleaner.deleteEmptyDirs(st, host.root(), host.cancelToken());
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                host.log("删除空目录：" + result, "success");
                host.toast("已删除 " + result + " 个空目录");
                host.invalidateScan();
            }
        });
    }

    /** 扁平化：把子文件夹里的文件全部拉到当前目录这一层（先预览再执行）。 */
    private void flatten() {
        if (host.repo.lastFiles.isEmpty()) {
            host.toast("请先点「自动整理」扫描一次");
            return;
        }
        host.runTask("扫描目录结构", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return Cleaner.planFlatten(st, host.root(), host.cancelToken());
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                @SuppressWarnings("unchecked")
                final List<Cleaner.FlattenPlan> plans = (List<Cleaner.FlattenPlan>) result;
                if (plans.isEmpty()) {
                    host.message("无需扁平化",
                            "当前目录这一层之外没有可上移的音频 / 歌词文件（可能都已经在这一层了）。");
                    return;
                }
                showFlattenPreview(plans);
            }
        });
    }

    private void showFlattenPreview(final List<Cleaner.FlattenPlan> plans) {
        List<PreviewSheet.Item> items = new ArrayList<PreviewSheet.Item>();
        for (final Cleaner.FlattenPlan p : plans) {
            items.add(new PreviewSheet.Item() {
                @Override
                public boolean isSelected() {
                    return p.selected;
                }

                @Override
                public void setSelected(boolean v) {
                    p.selected = v;
                }

                @Override
                public String title() {
                    return p.source.name;
                }

                @Override
                public String subtitle() {
                    StringBuilder sb = new StringBuilder("从 ");
                    sb.append(p.fromDir.isEmpty() ? "根目录" : p.fromDir);
                    sb.append(" → 当前目录");
                    if (p.renamed()) {
                        sb.append("（撞名，改为 ").append(p.targetName).append("）");
                    }
                    return sb.toString();
                }

                @Override
                public boolean warn() {
                    return false;
                }

                @Override
                public String detail() {
                    return "";
                }
            });
        }
        String hint = "把 " + plans.size() + " 个文件从子文件夹移到当前目录这一层。\n"
                + "撞名自动加 _2 / _3 序号；移动完成后删除空出来的子文件夹（「未识别」受保护）。\n"
                + "勾选要移动的，点「移动选中」执行。";
        PreviewSheet.show(host, "扁平化文件夹（预览）", hint, items, "移动选中", "取消",
                new PreviewSheet.Callback() {
                    @Override
                    public void onConfirm() {
                        executeFlatten(plans);
                    }
                });
    }

    private void executeFlatten(final List<Cleaner.FlattenPlan> plans) {
        host.runTask("扁平化", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return Cleaner.executeFlatten(st, host.root(), plans, host, host.cancelToken());
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                int[] r = (int[]) result;
                host.log("扁平化完成：移动 " + r[0] + "，失败 " + r[1]
                        + "，删除空目录 " + r[2], "success");
                host.toast("完成：移动 " + r[0] + "，删除空目录 " + r[2]);
                host.invalidateScan();
            }
        });
    }

    private void fetchLyrics() {
        host.confirm("批量歌词",
                "先联网匹配歌词（只读，不写任何文件），匹配完成后可预览勾选，确认后再写入。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        runFetch(host.repo.bool("lrc_overwrite", false), host.repo.bool("lrc_plain", false),
                                host.repo.bool("lrc_embed", true));
                    }
                });
    }

    /**
     * 执行歌词匹配。overwrite=false 时已有 .lrc 会被跳过；
     * 如果全被跳过（最常见的「一首都没匹配到」原因），直接问要不要覆盖重试。
     */
    private void runFetch(final boolean overwrite, final boolean acceptPlain,
                          final boolean embed) {
        final boolean recursive = host.repo.bool("recursive", true);
        final com.dsh.musicorganizer.core.BatchMemory memory = memory("lyrics");
        // 已获取的歌词边跑边收：用户暂停时可以直接预览这一部分
        final PartialSink<Lyrics.Match> sink = new PartialSink<Lyrics.Match>();
        final PartialPreview partial = new PartialPreview() {
            @Override
            public int count() {
                return sink.size();
            }

            @Override
            public void show(MainActivity h) {
                showLyricsPartial(sink, overwrite, embed);
            }
        };
        host.runTask("匹配歌词", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                List<VFile> files = Scanner.walkMusic(st, host.root(),
                        recursive, host.progressCallback(), host.cancelToken());
                // 根目录没扫到东西时自动递归一层，
                // 否则「未勾选子文件夹」会表现为「瞬间提示没有匹配到歌词」
                if (files.isEmpty() && !recursive) {
                    host.log("根目录没有音频，已自动改为递归扫描", "info");
                    files = Scanner.walkMusic(st, host.root(), true,
                            host.progressCallback(), host.cancelToken());
                }
                return Lyrics.fetchMatches(st, host.getContentResolver(), files,
                        overwrite, acceptPlain,
                        NameWeight.fromPercent(host.repo.intVal("fn_weight",
                                NameWeight.DEFAULT_PERCENT)),
                        sink, host.progressCallback(), host.cancelToken(), host, memory,
                        host.batchQueue("lyrics"));
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                // 用户已在暂停预览里接管（正在写入已获取部分），这里不要再弹结果
                if (host.consumePartialHandoff()) {
                    return;
                }
                if (error != null) {
                    host.fail(error);
                    return;
                }
                final Lyrics.FetchResult res = (Lyrics.FetchResult) result;
                if (res.stopped) {
                    // 停止时已获取的部分不该白丢：问一句要不要预览
                    if (!sink.isEmpty()) {
                        host.confirm("已停止匹配",
                                "已获取 " + sink.size() + " 首歌词，要预览已获取的部分吗？",
                                new Runnable() {
                                    @Override
                                    public void run() {
                                        showLyricsPartial(sink, overwrite, embed);
                                    }
                                });
                    } else {
                        host.toast("已停止，未生成预览");
                    }
                    return;
                }
                if (res.isEmpty()) {
                    host.log("歌词匹配：没有可写入的结果", "warning");
                    if (!overwrite && res.skippedExisting > 0) {
                        host.confirm("已有同名 .lrc",
                                res.explain() + "\n\n是否改为覆盖这些已有 .lrc 重新匹配？",
                                new Runnable() {
                                    @Override
                                    public void run() {
                                        runFetch(true, acceptPlain, embed);
                                    }
                                });
                        return;
                    }
                    host.message("没有匹配到歌词", res.explain());
                    return;
                }
                host.log("歌词匹配完成：共 " + res.matches.size()
                        + " 首，等待确认后写入", "info");
                LyricsPreview.showBatch(host, res.matches,
                        new LyricsPreview.OnConfirm() {
                            @Override
                            public void confirmed(List<Lyrics.Match> selected) {
                                writeLyrics(selected, overwrite, embed, false, memory);
                            }
                        });
            }
        }, partial);
    }

    /** 暂停时预览已获取的歌词；若用户确认写入，先结束匹配任务再写这部分。 */
    private void showLyricsPartial(final PartialSink<Lyrics.Match> sink,
                                   final boolean overwrite, final boolean embed) {
        final com.dsh.musicorganizer.core.BatchMemory memory = memory("lyrics");
        final List<Lyrics.Match> snapshot = sink.snapshot();
        if (snapshot.isEmpty()) {
            host.toast("还没有已获取的歌词");
            return;
        }
        LyricsPreview.showPartial(host, snapshot, new LyricsPreview.OnConfirm() {
            @Override
            public void confirmed(final List<Lyrics.Match> selected) {
                host.confirm("写入已获取的 " + selected.size() + " 首？",
                        "将结束当前匹配任务，只写入选中的歌词，未完成的部分不再查询。\n"
                                + "之后可以再点一次「批量歌词」继续处理剩下的。继续？",
                        new Runnable() {
                            @Override
                            public void run() {
                                writeLyrics(selected, overwrite, embed, true, memory);
                            }
                        });
            }
        });
    }

    /**
     * 用户确认后写入歌词。
     *
     * @param stopFirst true 表示「从暂停预览接管」：先停掉正在跑的匹配任务再写。
     */
    private void writeLyrics(final List<Lyrics.Match> selected, final boolean overwrite,
                             final boolean embed, final boolean stopFirst,
                             final com.dsh.musicorganizer.core.BatchMemory memory) {
        Tasks.Job job = new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return Lyrics.writeMatches(st, host.getContentResolver(), host, selected,
                        overwrite, embed, host.progressCallback(), host.cancelToken(), host,
                        memory, host.batchQueue("lyrics"));
            }
        };
        Tasks.Callback cb = new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                int[] r = (int[]) result;
                host.log("歌词写入：写入 " + r[0] + "，跳过 " + r[1] + "，失败 " + r[2], "success");
                host.toast("写入 " + r[0] + "，跳过 " + r[1] + "，失败 " + r[2]);
                host.invalidateScan();
            }
        };
        if (stopFirst) {
            host.stopCurrentThenRun("写入歌词", job, cb);
        } else {
            host.runTask("写入歌词", job, cb);
        }
    }

    /** 批量在线标签：先匹配（只读）→ 预览勾选 → 确认后事务写入。 */
    private void fetchTags() {
        final boolean cn = host.repo.bool("cn", true);
        final boolean recursive = host.repo.bool("recursive", true);
        final Map<String, Integer> fieldModes = resolvedFieldModes();
        final String policySummary = policySummaryText();
        final com.dsh.musicorganizer.core.BatchMemory memory = memory("tags");
        host.confirm("批量在线标签",
                "按字段写入策略（" + policySummary + "）先联网匹配出预览，勾选确认后才写入；\n"
                        + "写入走事务层，可整批撤销。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        // 已获取的标签边跑边收：暂停时可直接预览这一部分
                        final PartialSink<TagBatch.Match> sink =
                                new PartialSink<TagBatch.Match>();
                        final PartialPreview partial = new PartialPreview() {
                            @Override
                            public int count() {
                                return sink.size();
                            }

                            @Override
                            public void show(MainActivity h) {
                                showTagsPartial(sink);
                            }
                        };
                        host.runTask("匹配标签", new Tasks.Job() {
                            @Override
                            public Object run() throws Exception {
                                Storage st = host.safeStorage();
                                List<VFile> files = Scanner.walkMusic(st, host.root(),
                                        recursive, host.progressCallback(),
                                        host.cancelToken());
                                if (files.isEmpty() && !recursive) {
                                    host.log("根目录没有音频，已自动改为递归扫描", "info");
                                    files = Scanner.walkMusic(st, host.root(), true,
                                            host.progressCallback(), host.cancelToken());
                                }
                                return TagBatch.fetchMatches(st, host.getContentResolver(),
                                        host.repo.mb, files, fieldModes,
                                        NameWeight.fromPercent(host.repo.intVal("fn_weight",
                                                NameWeight.DEFAULT_PERCENT)),
                                        cn, sink, uiProgress(),
                                        host.cancelToken(), host, memory, null,
                                        host.batchQueue("tags"));
                            }
                        }, new Tasks.Callback() {
                            @Override
                            public void done(Object result, Exception error) {
                                // 用户已在暂停预览里接管，不要再弹自己的结果
                                if (host.consumePartialHandoff()) {
                                    return;
                                }
                                if (error != null) {
                                    host.fail(error);
                                    return;
                                }
                                if (host.lastTaskStopped()) {
                                    // 停止时已获取的部分不该白丢
                                    if (!sink.isEmpty()) {
                                        host.confirm("已停止匹配",
                                                "已获取 " + sink.size() + " 首标签，"
                                                        + "要预览已获取的部分吗？",
                                                new Runnable() {
                                                    @Override
                                                    public void run() {
                                                        showTagsPartial(sink);
                                                    }
                                                });
                                    } else {
                                        host.toast("已停止，未生成预览");
                                    }
                                    return;
                                }
                                @SuppressWarnings("unchecked")
                                final List<TagBatch.Match> matches = (List<TagBatch.Match>) result;
                                if (matches.isEmpty()) {
                                    host.log("标签匹配：没有可写入的候选", "warning");
                                    host.message("没有匹配到标签",
                                            "共扫描到音频文件，但没有可补/可改的字段。\n\n"
                                                    + "可能原因：\n"
                                                    + "· 标签已经很完整，或字段策略里这些字段设成了「不写 / 只补空」\n"
                                                    + "· 库里没有对应条目或置信度太低\n"
                                                    + "· 只支持写入 MP3 / FLAC\n\n"
                                                    + "详细原因见「日志」页。");
                                    return;
                                }
                                host.log("标签匹配完成：共 " + matches.size()
                                        + " 首，等待确认后写入", "info");
                                TagPreview.showBatch(host, matches, policySummary,
                                        new TagPreview.OnConfirm() {
                                            @Override
                                            public void confirmed(List<TagBatch.Match> selected) {
                                                writeTags(selected, false, memory);
                                            }
                                        });
                            }
                        }, partial);
                    }
                });
    }

    /** 合并全局「覆盖已有标签」开关与字段级自定义，得到每字段最终策略。 */
    private Map<String, Integer> resolvedFieldModes() {
        Map<String, Integer> m = TagFill.defaultModes(host.repo.bool("tag_overwrite", false));
        m.putAll(host.repo.tagFieldModes());
        return m;
    }

    /** 字段策略的一句话摘要（批量标签确认框用；编辑入口在「设置」页）。 */
    private String policySummaryText() {
        Map<String, Integer> custom = host.repo.tagFieldModes();
        if (custom.isEmpty()) {
            return host.repo.bool("tag_overwrite", false) ? "全部覆盖" : "全部只补空";
        }
        StringBuilder sb = new StringBuilder("自定义：");
        Map<String, Integer> resolved = resolvedFieldModes();
        for (String f : TagFill.CANDIDATE_FIELDS) {
            if (sb.length() > 4) {
                sb.append('、');
            }
            sb.append(TagFill.label(f)).append('·').append(TagFill.modeName(TagFill.modeOf(resolved, f)));
        }
        return sb.toString();
    }

    /** 暂停时预览已获取的标签；若用户确认写入，先结束匹配任务再写这部分。 */
    private void showTagsPartial(final PartialSink<TagBatch.Match> sink) {
        final com.dsh.musicorganizer.core.BatchMemory memory = memory("tags");
        final List<TagBatch.Match> snapshot = sink.snapshot();
        if (snapshot.isEmpty()) {
            host.toast("还没有已获取的标签");
            return;
        }
        TagPreview.showPartial(host, snapshot, new TagPreview.OnConfirm() {
            @Override
            public void confirmed(final List<TagBatch.Match> selected) {
                host.confirm("写入已获取的 " + selected.size() + " 首？",
                        "将结束当前匹配任务，只写入选中的标签，未完成的部分不再查询。\n"
                                + "写入走事务层，可整批撤销。继续？",
                        new Runnable() {
                            @Override
                            public void run() {
                                writeTags(selected, true, memory);
                            }
                        });
            }
        });
    }

    /**
     * 用户确认后写入选中条目。
     *
     * @param stopFirst true 表示「从暂停预览接管」：先停掉正在跑的匹配任务再写。
     */
    private void writeTags(final List<TagBatch.Match> selected, final boolean stopFirst,
                           final com.dsh.musicorganizer.core.BatchMemory memory) {
        final List<String> errors = new ArrayList<String>();
        Tasks.Job job = new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return TagBatch.writeMatches(st, host.getContentResolver(), host, selected,
                        uiProgress(), host.cancelToken(), host, errors, memory,
                        host.batchQueue("tags"));
            }
        };
        Tasks.Callback cb = new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                int[] r = (int[]) result;
                host.log("批量标签写入：成功 " + r[0] + "，跳过 " + r[1]
                        + "，失败 " + r[2] + "（可在「安全网」整批撤销）", "success");
                host.toast("写入 " + r[0] + "，跳过 " + r[1] + "，失败 " + r[2]);
                if (r[2] > 0 && !errors.isEmpty()) {
                    // 只报「失败 N 个」等于没说：把前几条原因直接摆出来
                    StringBuilder sb = new StringBuilder();
                    sb.append("共 ").append(r[2]).append(" 个文件没能写入，原因如下：");
                    for (String e : errors) {
                        sb.append("\n\n· ").append(e);
                    }
                    sb.append("\n\n完整记录见下方任务日志。");
                    host.message("标签写入失败", sb.toString());
                }
                host.invalidateScan();
            }
        };
        if (stopFirst) {
            host.stopCurrentThenRun("写入标签", job, cb);
        } else {
            host.runTask("写入标签", job, cb);
        }
    }

    /** 增量模式开启时返回匹配记忆，否则 null（等于不记忆）。 */
    private com.dsh.musicorganizer.core.BatchMemory memory(String kind) {
        if (!host.repo.bool("incremental", true)) {
            return null;
        }
        return host.batchMemory(kind);
    }

    /** 批量补封面：先匹配（不下载）→ 预览勾选 → 下载 + 事务写入。 */
    private void fetchCovers() {
        final boolean cn = host.repo.bool("cn", true);
        final boolean recursive = host.repo.bool("recursive", true);
        final boolean overwriteCover = host.repo.bool("cover_overwrite", false);
        final com.dsh.musicorganizer.core.BatchMemory memory = memory("cover");
        host.confirm("批量补封面",
                (overwriteCover ? "将替换已有封面。" : "只补没有封面的文件。")
                        + "\n先联网匹配专辑图（只读），可预览勾选后再写入。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        host.runTask("匹配封面", new Tasks.Job() {
                            @Override
                            public Object run() throws Exception {
                                Storage st = host.safeStorage();
                                List<VFile> files = Scanner.walkMusic(st, host.root(),
                                        recursive, host.progressCallback(),
                                        host.cancelToken());
                                if (files.isEmpty() && !recursive) {
                                    host.log("根目录没有音频，已自动改为递归扫描", "info");
                                    files = Scanner.walkMusic(st, host.root(), true,
                                            host.progressCallback(), host.cancelToken());
                                }
                                return com.dsh.musicorganizer.core.CoverBatch.fetchMatches(st,
                                        host.getContentResolver(), host.repo.mb, files,
                                        NameWeight.fromPercent(host.repo.intVal("fn_weight",
                                                NameWeight.DEFAULT_PERCENT)),
                                        cn, overwriteCover,
                                        host.progressCallback(), host.cancelToken(), host, memory);
                            }
                        }, new Tasks.Callback() {
                            @Override
                            public void done(Object result, Exception error) {
                                if (error != null) {
                                    host.fail(error);
                                    return;
                                }
                                final com.dsh.musicorganizer.core.CoverBatch.Result res =
                                        (com.dsh.musicorganizer.core.CoverBatch.Result) result;
                                if (host.lastTaskStopped()) {
                                    host.toast("已停止匹配");
                                    return;
                                }
                                if (res.isEmpty()) {
                                    host.message("没有可补的封面", res.explain());
                                    return;
                                }
                                host.log("封面匹配完成：" + res.matches.size()
                                        + " 首，等待确认后写入", "info");
                                CoverPreview.showBatch(host, res.matches,
                                        new CoverPreview.OnConfirm() {
                                            @Override
                                            public void confirmed(
                                                    final List<com.dsh.musicorganizer.core
                                                            .CoverBatch.Match> selected) {
                                                writeCovers(selected, memory);
                                            }
                                        });
                            }
                        });
                    }
                });
    }

    private void writeCovers(final List<com.dsh.musicorganizer.core.CoverBatch.Match> selected,
                             final com.dsh.musicorganizer.core.BatchMemory memory) {
        host.runTask("写入封面", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return com.dsh.musicorganizer.core.CoverBatch.writeMatches(st,
                        host.getContentResolver(), host, selected,
                        host.progressCallback(), host.cancelToken(), host, memory);
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                int[] r = (int[]) result;
                host.log("封面写入：成功 " + r[0] + "，跳过 " + r[1] + "，失败 " + r[2], "success");
                host.toast("封面写入 " + r[0] + "，失败 " + r[2]);
                host.invalidateScan();
            }
        });
    }

    /** 撤销上次自动整理：按移动日志把文件搬回原目录原名（v0.1.39）。 */
    private void revertLastOrganize() {
        final java.util.List<MoveLog.Batch> batches = MoveJournal.batches(host, 1);
        if (batches.isEmpty()) {
            host.message("撤销上次整理",
                    "还没有整理记录。\n\n每次自动整理都会记下「从哪搬到哪」，"
                            + "整理完之后可以整批搬回去；只预览（仅预览不移动）不会产生记录。");
            return;
        }
        final MoveLog.Batch batch = batches.get(0);
        host.confirm("撤销上次整理",
                "把 " + batch.title() + " 的文件搬回原目录原名？\n\n"
                        + "原位置被占用的会加序号（不覆盖现有文件）；已经在别处又搬走/删掉的会跳过并计入失败。",
                new Runnable() {
                    @Override
                    public void run() {
                        host.runTask("撤销上次整理", new Tasks.Job() {
                            @Override
                            public Object run() throws Exception {
                                Storage st = host.safeStorage();
                                return MoveJournal.revert(st, host, batch.batchId, host);
                            }
                        }, new Tasks.Callback() {
                            @Override
                            public void done(Object result, Exception error) {
                                if (error != null) {
                                    host.fail(error);
                                    return;
                                }
                                int[] r = (int[]) result;
                                host.toast("搬回 " + r[0] + " 个"
                                        + (r[1] > 0 ? "，失败 " + r[1] : ""));
                                host.invalidateScan();
                            }
                        });
                    }
                });
    }

    private void revertLast() {
        host.runTask("撤销标签写入", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return TagTransaction.revertLastBatch(st, host.getContentResolver(), host, host);
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
                    host.toast("没有可撤销的记录");
                } else {
                    host.toast("已撤销 " + r[0] + " 首" + (r[1] > 0 ? "，失败 " + r[1] : ""));
                }
                host.invalidateScan();
            }
        });
    }
}
