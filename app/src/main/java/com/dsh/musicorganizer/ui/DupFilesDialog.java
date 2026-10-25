package com.dsh.musicorganizer.ui;

import android.app.Dialog;
import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.DupFiles;
import com.dsh.musicorganizer.core.HealthCheck;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.VFile;

import java.io.File;
import java.io.FileInputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 重复文件（按内容）：找出头部 64KB 完全相同的音频，保留一份、删掉多余的（v0.1.58）。
 *
 * <p>为什么按内容而不是文件名：整理过几轮之后，同一首歌会变成「歌.mp3」「歌 (1).mp3」
 * 「歌_2.mp3」散落各处，文件名相似度未必够，但内容一模一样。用户报的
 * 「播放器 911、本机 1213」就是这类重复。
 *
 * <p>安全线：只在「大小相同 + 头部 64KB 的 SHA-256 相同」时才算重复；
 * 建议保留层级最浅的那一份，其余默认勾选待删；删除前二次确认，删完重新扫描。
 */
public final class DupFilesDialog {

    private DupFilesDialog() {
    }

    public static void show(final MainActivity host) {
        if (host == null) {
            return;
        }
        if (host.repo.lastFiles.isEmpty()) {
            host.toast("先扫描一次目录（整理页 →「自动整理」）");
            return;
        }
        host.runTask("查找重复文件", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                List<DupFiles.Item> all = new ArrayList<DupFiles.Item>();
                for (VFile f : host.repo.lastFiles) {
                    if (f == null || f.dir || !f.audio()) {
                        continue;
                    }
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    all.add(new DupFiles.Item(f.docId, f.pathAfterRoot(), f.name, f.size));
                }
                // 先按大小分桶：绝大多数文件在这一步就被排除，只给同大小的算哈希
                List<List<DupFiles.Item>> buckets = DupFiles.bySize(all);
                List<DupFiles.Item> candidates = new ArrayList<DupFiles.Item>();
                for (List<DupFiles.Item> bucket : buckets) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    for (DupFiles.Item it : bucket) {
                        // v0.1.88：大小 + 头 + 尾采样。老实现只看头 64KB，
                        // 「同一编码器批量导出、头部一致、后面不同」的文件会被误判成同一份。
                        VFile target = findFile(host.repo.lastFiles, it.docId);
                        if (target != null) {
                            byte[] head = st.headBytes(target, DupFiles.HEAD_BYTES);
                            byte[] tail = st.tailBytes(target, DupFiles.TAIL_BYTES);
                            it.hash = DupFiles.sampleHash(head, tail, it.size);
                        }
                        candidates.add(it);
                    }
                }
                return DupFiles.groups(candidates);
            }
        }, new Tasks.Callback() {
            @Override
            @SuppressWarnings("unchecked")
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                List<DupFiles.Group> groups = (List<DupFiles.Group>) result;
                if (groups == null || groups.isEmpty()) {
                    host.message("没有发现重复文件",
                            "按「大小相同 + 头尾各 64KB 内容相同」比对，没有找到重复的音频。\n\n"
                                    + "如果曲目数仍比播放器多，可能是这些歌名字不同、内容也略有差别"
                                    + "（不同码率 / 不同版本），可以再用「文件名查重」看看。");
                    return;
                }
                host.log("重复文件：" + DupFiles.summary(groups), "warning");
                openPanel(host, groups);
            }
        });
    }

    /** 按 docId 找当前扫描结果里的文件对象（读头尾采样用）。 */
    private static VFile findFile(List<VFile> files, String docId) {
        if (files == null || docId == null) {
            return null;
        }
        for (VFile f : files) {
            if (f != null && docId.equals(f.docId)) {
                return f;
            }
        }
        return null;
    }

    private static void openPanel(final MainActivity host, final List<DupFiles.Group> groups) {
        final Context ctx = host;
        LinearLayout root = UiKit.vertical(ctx);
        int pad = UiKit.dp(ctx, 14);
        root.setPadding(pad, pad, pad, pad);

        root.addView(UiKit.text(ctx, "重复文件", 18, UiKit.textColor(), true));
        TextView hint = UiKit.caption(ctx,
                DupFiles.summary(groups) + "。默认保留层级最浅的那一份，其余已勾选。"
                        + "删除不进回收站，确认前请看清楚路径。");
        hint.setLineSpacing(UiKit.dp(ctx, 2), 1f);
        UiKit.margin(hint, 0, 6, 0, 8);
        root.addView(hint);

        final Map<String, CheckBox> boxes = new HashMap<String, CheckBox>();
        final Map<String, VFile> byId = new HashMap<String, VFile>();
        for (VFile f : host.repo.lastFiles) {
            if (f != null && !f.dir) {
                byId.put(f.docId, f);
            }
        }

        ScrollView scroll = new ScrollView(ctx);
        LinearLayout list = UiKit.vertical(ctx);
        for (int gi = 0; gi < groups.size(); gi++) {
            DupFiles.Group g = groups.get(gi);
            LinearLayout card = UiKit.card(ctx);
            UiKit.margin(card, 0, gi == 0 ? 0 : 10, 0, 0);
            card.addView(UiKit.text(ctx, g.items.size() + " 个内容相同 · "
                    + HealthCheck.size(g.size()) + " · 可省 " + HealthCheck.size(g.wasted()),
                    14, UiKit.textColor(), true));
            DupFiles.Item keep = g.suggestKeep();
            for (DupFiles.Item it : g.items) {
                boolean isKeep = it == keep;
                String label = (isKeep ? "【建议保留】" : "") + it.path + "\n"
                        + HealthCheck.size(it.size);
                CheckBox box = UiKit.checkbox(ctx, label, !isKeep);
                UiKit.margin(box, 0, 6, 0, 0);
                // 保留项不再强制锁定：用户可能想删掉被推荐保留的那一份。
                // 只在删除前校验「每组至少留一个」，避免误删唯一副本。
                VFile f = byId.get(it.docId);
                if (f != null) {
                    boxes.put(it.docId, box);
                }
                card.addView(box);
            }
            list.addView(card);
        }
        scroll.addView(list);
        root.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        final Button del = UiKit.button(ctx, "删除勾选的副本", true);
        Button cancel = UiKit.button(ctx, "取消", false);
        UiKit.margin(del, 0, 8, 0, 0);
        UiKit.margin(cancel, 0, 6, 0, 0);
        root.addView(del);
        root.addView(cancel);

        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT);
        }
        dialog.show();

        cancel.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
            }
        });
        del.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                final List<VFile> selected = new ArrayList<VFile>();
                for (Map.Entry<String, CheckBox> e : boxes.entrySet()) {
                    if (e.getValue().isChecked()) {
                        VFile f = byId.get(e.getKey());
                        if (f != null) {
                            selected.add(f);
                        }
                    }
                }
                if (selected.isEmpty()) {
                    host.toast("没有勾选任何文件");
                    return;
                }
                // 每组至少保留一个，禁止把整组删光（否则会丢失这首歌）
                for (DupFiles.Group g : groups) {
                    int total = g.items.size();
                    int willDelete = 0;
                    for (DupFiles.Item it : g.items) {
                        CheckBox b = boxes.get(it.docId);
                        if (b != null && b.isChecked()) {
                            willDelete++;
                        }
                    }
                    if (willDelete >= total) {
                        host.toast("每组至少保留一个文件，不能把「"
                                + g.items.get(0).name + "」所在组整组删光");
                        return;
                    }
                }
                host.confirm("删除 " + selected.size() + " 个副本",
                        "这些文件不进回收站，删掉找不回来。确认只删副本、保留的那份不动？",
                        new Runnable() {
                            @Override
                            public void run() {
                                dialog.dismiss();
                                delete(host, selected);
                            }
                        });
            }
        });
    }

    private static void delete(final MainActivity host, final List<VFile> files) {
        host.runTask("删除重复副本", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                int ok = 0;
                int failed = 0;
                long freed = 0;
                List<String> failedNames = new ArrayList<String>();
                for (VFile f : files) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    String reason = st.deleteWithReason(f);
                    if (reason == null) {
                        ok++;
                        freed += f.size;
                    } else {
                        failed++;
                        failedNames.add(f.name + "：" + reason);
                    }
                }
                return new Object[]{Integer.valueOf(ok), Integer.valueOf(failed),
                        Long.valueOf(freed), failedNames};
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
                int failed = ((Integer) arr[1]).intValue();
                long freed = ((Long) arr[2]).longValue();
                @SuppressWarnings("unchecked")
                List<String> failedNames = (List<String>) arr[3];
                StringBuilder detail = new StringBuilder();
                for (String s : failedNames) {
                    if (detail.length() > 0) {
                        detail.append("\n");
                    }
                    detail.append(s);
                }
                host.log("删除重复副本：成功 " + ok + "，失败 " + failed
                        + "，释放 " + HealthCheck.size(freed)
                        + (detail.length() == 0 ? "" : "\n失败明细：\n" + detail),
                        failed > 0 ? "warning" : "success");
                host.toast("已删除 " + ok + " 个副本，释放 " + HealthCheck.size(freed)
                        + (failed == 0 ? "" : "，失败 " + failed + " 个"));
                host.invalidateScan();
            }
        });
    }
}
