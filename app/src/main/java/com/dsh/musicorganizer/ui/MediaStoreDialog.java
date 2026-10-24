package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.net.Uri;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.HealthCheck;
import com.dsh.musicorganizer.core.MediaStoreScan;
import com.dsh.musicorganizer.core.MediaTrack;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.VFile;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 系统媒体库（MediaStore）扫描 + 导入（v0.1.42）。
 *
 * <p>SAF 选不到的目录（典型是「下载」根目录，Android 11+ 限制）在系统媒体库里是可见的。
 * 本面板把媒体库里的音频列出来（标题 / 艺人 / 专辑 / 时长 / 大小 / 路径），
 * 勾选后**复制**到当前授权目录 —— 导入后就是普通文件，标签、歌词、整理、重命名全套可用。
 *
 * <p>为什么只做导入、不直接改：媒体库给的是 {@code content://media/...}，没有 document URI，
 * 写入标签的事务层全部基于 DocumentsContract，硬接会绕开「副本写 + 回读校验」的安全线。
 */
public final class MediaStoreDialog {

    private MediaStoreDialog() {
    }

    /** 时长下限：短于 30 秒的基本是铃声/提示音，默认挡住。 */
    private static final long MIN_DURATION_MS = 30_000L;

    /** 列表最多渲染多少行（避免一次性建上千个 View 卡住）。 */
    private static final int RENDER_LIMIT = 300;

    public static void show(final MainActivity host) {
        if (!MediaStoreScan.hasPermission(host)) {
            new UiKit.Builder(host)
                    .setTitle("读取系统媒体库")
                    .setMessage("为什么要这个权限：\n\n"
                            + "· 手机里有些目录（尤其是「下载」根目录）系统不允许手动选授权，"
                            + "应用里扫不到，但系统媒体库能看到；\n"
                            + "· 有了它才能把这些歌列出来并复制到你选过的目录里；\n"
                            + "· 只读取音频的标题/艺人/专辑/时长这几项，不读照片、不联网、不上传。")
                    .setNegativeButton("取消", null)
                    .setPositiveButton("去授权", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface d, int which) {
                            host.requestMediaPermission();
                        }
                    })
                    .show();
            return;
        }

        final Context ctx = host;
        final LinearLayout root = UiKit.vertical(ctx);
        root.setBackgroundColor(UiKit.bgColor());
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);

        root.addView(UiKit.text(ctx, "系统媒体库", 18, UiKit.textColor(), true));
        final TextView status = UiKit.caption(ctx, "正在读取系统媒体库…（上千首需要几秒）");
        UiKit.margin(status, 0, 6, 0, 8);
        root.addView(status);

        final EditText search = UiKit.input(ctx, "筛选：歌名 / 艺人 / 专辑 / 目录");
        search.setSingleLine(true);
        root.addView(search);

        final LinearLayout chipRow = UiKit.horizontal(ctx);
        chipRow.setGravity(Gravity.CENTER_VERTICAL);
        root.addView(chipRow);

        final CountText count = new CountText(ctx);
        root.addView(count.view);

        final TrackAdapter adapter = new TrackAdapter(ctx);
        ListView list = new ListView(ctx);
        list.setDivider(null);
        list.setDividerHeight(UiKit.dp(ctx, 6));
        list.setVerticalScrollBarEnabled(false);
        list.setAdapter(adapter);
        root.addView(list, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        final Button importBtn = UiKit.button(ctx, "导入到当前目录", true);
        Button close = UiKit.button(ctx, "关闭", false);
        UiKit.margin(importBtn, 0, 8, 0, 0);
        UiKit.margin(close, 0, 8, 0, 0);
        root.addView(importBtn);
        root.addView(close);

        // 全屏 Dialog 而不是 AlertDialog：AlertDialog 会把自定义布局塞进 ScrollView，
        // 里面的 ListView 用「高度 0 + weight 1」会被压成 0 高（列表看不见）。
        final android.app.Dialog dialog = new android.app.Dialog(ctx);
        dialog.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        dialog.setContentView(root);
        android.view.Window window = dialog.getWindow();
        if (window != null) {
            window.setLayout(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT);
        }
        dialog.show();

        close.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
            }
        });

        // 全选 / 全不选 + 只看未导入
        final TextView selAll = UiKit.chip(ctx, "全选", false);
        final TextView selNone = UiKit.chip(ctx, "全不选", false);
        final TextView onlyNew = UiKit.chip(ctx, "只看未导入", false);
        final boolean[] showOnlyNew = new boolean[]{false};
        UiKit.margin(selAll, 0, 6, 6, 0);
        UiKit.margin(selNone, 0, 0, 6, 0);
        UiKit.margin(onlyNew, 0, 0, 0, 0);
        chipRow.addView(selAll);
        chipRow.addView(selNone);
        chipRow.addView(onlyNew);

        selAll.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                adapter.setAll(true);
                count.refresh();
            }
        });
        selNone.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                adapter.setAll(false);
                count.refresh();
            }
        });
        onlyNew.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                showOnlyNew[0] = !showOnlyNew[0];
                UiKit.setChip(onlyNew, showOnlyNew[0]);
                adapter.setOnlyNew(showOnlyNew[0]);
                count.refresh();
            }
        });

        adapter.onChange = new Runnable() {
            @Override
            public void run() {
                count.refresh();
            }
        };
        count.bind(new Runnable() {
            @Override
            public void run() {
                List<MediaTrack> sel = adapter.checked();
                count.view.setText("已选 " + sel.size() + " 首 · "
                        + HealthCheck.size(MediaTrack.totalSize(sel))
                        + " · 当前列表 " + adapter.getCount() + " 行");
                importBtn.setText(sel.isEmpty() ? "导入到当前目录"
                        : "导入 " + sel.size() + " 首");
            }
        });

        search.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {
            }

            @Override
            public void onTextChanged(CharSequence s, int a, int b, int c) {
            }

            @Override
            public void afterTextChanged(Editable s) {
                adapter.setQuery(s.toString());
                count.refresh();
            }
        });

        importBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                final List<MediaTrack> picked = adapter.checked();
                if (picked.isEmpty()) {
                    host.toast("还没有勾选任何歌曲");
                    return;
                }
                new UiKit.Builder(ctx)
                        .setTitle("导入 " + picked.size() + " 首")
                        .setMessage("把选中的歌复制到当前目录（" + host.repo.treeDisplayName()
                                + "）。\n\n"
                                + "· 只是复制，系统媒体库里的原文件不动；\n"
                                + "· 曲库里已有同名同大小的会跳过（不会重复导入）；\n"
                                + "· 共 " + HealthCheck.size(MediaTrack.totalSize(picked))
                                + "，导入后就能用标签/歌词/整理等功能。")
                        .setNegativeButton("取消", null)
                        .setPositiveButton("开始导入", new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface d, int which) {
                                runImport(host, picked, adapter, count, status);
                            }
                        })
                        .show();
            }
        });

        // 后台读媒体库
        new Thread(new Runnable() {
            @Override
            public void run() {
                final List<MediaTrack> tracks = MediaStoreScan.scan(host, MIN_DURATION_MS);
                host.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        adapter.setTracks(tracks);
                        status.setText(MediaTrack.summary(tracks)
                                + (tracks.isEmpty() ? "（系统媒体库还没索引到？先让系统音乐播放器扫一次）"
                                : " · 时长 <30 秒的铃声已隐藏"));
                        count.refresh();
                    }
                });
            }
        }).start();
    }

    /** 逐首复制到当前 SAF 目录（长任务，可暂停/取消）。 */
    private static void runImport(final MainActivity host, final List<MediaTrack> tracks,
                                  final TrackAdapter adapter, final CountText count,
                                  final TextView status) {
        host.runTask("导入媒体库歌曲", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                VFile root = host.root();
                Set<String> existing = new HashSet<String>();
                for (VFile child : st.children(root)) {
                    existing.add(child.name);
                }
                // 曲库全量索引（v0.1.59）：以前只跟**根目录**里的名字比，
                // 于是「已经在 歌手/ 子目录里的歌」会被再复制一份到根目录 ——
                // 这正是「整理完根目录多出几百个重复文件」的来源。
                // 现在把整个曲库按「大小 → 文件名」建索引，同名同大小就跳过。
                Map<Long, Set<String>> libBySize = new HashMap<Long, Set<String>>();
                for (VFile f : host.repo.lastFiles) {
                    if (f == null || f.dir || !f.audio()) {
                        continue;
                    }
                    Set<String> names = libBySize.get(f.size);
                    if (names == null) {
                        names = new HashSet<String>();
                        libBySize.put(f.size, names);
                    }
                    names.add(f.name);
                }
                int ok = 0;
                int failed = 0;
                int skipped = 0;
                long copied = 0;
                List<String> errors = new ArrayList<String>();
                for (MediaTrack t : tracks) {
                    if (host.cancelToken().isCancelled()) {
                        break;
                    }
                    File tmp = null;
                    try {
                        String name = MediaTrack.safeFileName(t);
                        Set<String> sameSize = libBySize.get(t.size);
                        if (sameSize != null && sameSize.contains(name)) {
                            // 曲库里已经有同名同大小的文件（多半就是它自己）：跳过，不再复制
                            skipped++;
                            continue;
                        }
                        int n = 2;
                        while (existing.contains(name)) {
                            name = withIndex(name, n++);
                        }
                        tmp = File.createTempFile("mo_import_", ".bin");
                        Uri uri = MediaStoreScan.uriOf(t);
                        InputStream in = host.getContentResolver().openInputStream(uri);
                        if (in == null) {
                            failed++;
                            errors.add(t.display() + "（打不开）");
                            continue;
                        }
                        FileOutputStream out = new FileOutputStream(tmp);
                        byte[] buf = new byte[64 * 1024];
                        int r;
                        long total = 0;
                        while ((r = in.read(buf)) > 0) {
                            out.write(buf, 0, r);
                            total += r;
                        }
                        out.close();
                        in.close();
                        String mime = t.mime.isEmpty() ? "audio/mpeg" : t.mime;
                        VFile created = st.createFile(root, name, mime);
                        if (created == null) {
                            failed++;
                            errors.add(t.display() + "（创建文件失败）");
                            continue;
                        }
                        st.writeFromLocal(created, tmp);
                        existing.add(name);
                        Set<String> bucket = libBySize.get(t.size);
                        if (bucket == null) {
                            bucket = new HashSet<String>();
                            libBySize.put(t.size, bucket);
                        }
                        bucket.add(name);
                        ok++;
                        copied += total;
                        t.imported = true;
                    } catch (Exception e) {
                        failed++;
                        if (errors.size() < 30) {
                            errors.add(t.display() + "（" + e.getClass().getSimpleName() + "）");
                        }
                    } finally {
                        if (tmp != null) {
                            //noinspection ResultOfMethodCallIgnored
                            tmp.delete();
                        }
                    }
                }
                return new Object[]{Integer.valueOf(ok), Integer.valueOf(failed),
                        Long.valueOf(copied), errors, Integer.valueOf(skipped)};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                Object[] r = (Object[]) result;
                int ok = ((Integer) r[0]).intValue();
                int failed = ((Integer) r[1]).intValue();
                long copied = ((Long) r[2]).longValue();
                @SuppressWarnings("unchecked")
                List<String> errors = (List<String>) r[3];
                int skipped = r.length > 4 ? ((Integer) r[4]).intValue() : 0;
                host.log("导入媒体库：成功 " + ok + " 首（" + HealthCheck.size(copied) + "）"
                        + (skipped > 0 ? "，跳过曲库已有的 " + skipped + " 首" : "")
                        + (failed > 0 ? "，失败 " + failed + " 首" : ""),
                        failed > 0 ? "warning" : "success");
                for (int i = 0; i < Math.min(errors.size(), 5); i++) {
                    host.log("导入失败：" + errors.get(i), "error");
                }
                host.toast("已导入 " + ok + " 首"
                        + (skipped > 0 ? "，跳过 " + skipped + " 首（曲库已有）" : "")
                        + (failed > 0 ? "，失败 " + failed : ""));
                status.setText("已导入 " + ok + " 首（" + HealthCheck.size(copied) + "）"
                        + (skipped > 0 ? "，跳过 " + skipped + " 首" : "")
                        + (failed > 0 ? "，失败 " + failed : ""));
                adapter.notifyDataSetChanged();
                count.refresh();
                host.invalidateScan();
            }
        });
    }

    private static String withIndex(String name, int index) {
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        return stem + " (" + index + ")" + ext;
    }

    /** 「已选 N 首 · 12.3 MB」这行：真正的计算在界面层注入，避免适配器反向依赖。 */
    private static final class CountText {
        final TextView view;
        private Runnable impl;

        CountText(Context ctx) {
            view = UiKit.caption(ctx, "");
            UiKit.margin(view, 0, 6, 0, 4);
        }

        void bind(Runnable value) {
            impl = value;
        }

        void refresh() {
            if (impl != null) {
                impl.run();
            }
        }
    }

    /** 列表：勾选框 + 两行信息。 */
    private static final class TrackAdapter extends BaseAdapter {
        private final Context ctx;
        private final List<MediaTrack> all = new ArrayList<MediaTrack>();
        private final List<MediaTrack> shown = new ArrayList<MediaTrack>();
        private final Set<Long> checked = new HashSet<Long>();
        private String query = "";
        private boolean onlyNew;
        Runnable onChange;

        TrackAdapter(Context ctx) {
            this.ctx = ctx;
        }

        void setTracks(List<MediaTrack> tracks) {
            all.clear();
            all.addAll(tracks);
            rebuild();
        }

        void setQuery(String q) {
            query = q == null ? "" : q;
            rebuild();
        }

        void setOnlyNew(boolean value) {
            onlyNew = value;
            rebuild();
        }

        void setAll(boolean value) {
            checked.clear();
            if (value) {
                for (MediaTrack t : shown) {
                    checked.add(Long.valueOf(t.id));
                }
            }
            notifyDataSetChanged();
        }

        List<MediaTrack> checked() {
            List<MediaTrack> out = new ArrayList<MediaTrack>();
            for (MediaTrack t : all) {
                if (checked.contains(Long.valueOf(t.id))) {
                    out.add(t);
                }
            }
            return out;
        }

        private void rebuild() {
            List<MediaTrack> filtered = MediaTrack.filter(all, query);
            shown.clear();
            for (MediaTrack t : filtered) {
                if (onlyNew && t.imported) {
                    continue;
                }
                shown.add(t);
                if (shown.size() >= RENDER_LIMIT) {
                    break;
                }
            }
            notifyDataSetChanged();
        }

        @Override
        public int getCount() {
            return shown.size();
        }

        @Override
        public Object getItem(int position) {
            return shown.get(position);
        }

        @Override
        public long getItemId(int position) {
            return shown.get(position).id;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            final MediaTrack t = shown.get(position);
            LinearLayout card = UiKit.card(ctx);
            LinearLayout head = UiKit.horizontal(ctx);
            final CheckBox box = UiKit.checkbox(ctx, "", checked.contains(Long.valueOf(t.id)));
            box.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
                @Override
                public void onCheckedChanged(CompoundButton b, boolean value) {
                    if (value) {
                        checked.add(Long.valueOf(t.id));
                    } else {
                        checked.remove(Long.valueOf(t.id));
                    }
                    if (onChange != null) {
                        onChange.run();
                    }
                }
            });
            head.addView(box);
            TextView title = UiKit.text(ctx, t.display(), 14, UiKit.textColor(), false);
            head.addView(title, new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            if (t.imported) {
                head.addView(UiKit.badge(ctx, "已导入", UiKit.okColor()));
            }
            card.addView(head);
            TextView sub = UiKit.caption(ctx, t.detail());
            UiKit.margin(sub, 0, 2, 0, 0);
            card.addView(sub);
            return card;
        }
    }
}
