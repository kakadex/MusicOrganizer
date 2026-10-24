package com.dsh.musicorganizer.core;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * 整理移动日志的落盘与「搬回原处」（v0.1.39）。
 *
 * <p>标签写入早就有 `Journal` 可以按批撤销，但**文件移动**一直没有记录：整理跑完几百组之后
 * 想反悔，只能自己一个个翻目录搬回去。这里把每次移动落一行，按批次整批搬回原位。
 *
 * <p>数据格式与分组计算在 {@link MoveLog}（纯 Java，可回归）；本类只负责读写文件与调用 Storage。
 */
public final class MoveJournal {

    private MoveJournal() {
    }

    /** 最多保留多少条（一次整理几百条，够回溯十几轮）。 */
    private static final int MAX_LINES = 5000;

    private static File file(Context ctx) {
        return new File(ctx.getFilesDir(), "move_journal.tsv");
    }

    public static synchronized boolean append(Context ctx, List<MoveLog.Record> records) {
        if (ctx == null || records == null || records.isEmpty()) {
            return false;
        }
        try {
            List<MoveLog.Record> all = readAll(ctx);
            all.addAll(records);
            if (all.size() > MAX_LINES) {
                all = new ArrayList<MoveLog.Record>(all.subList(all.size() - MAX_LINES, all.size()));
            }
            StringBuilder sb = new StringBuilder(all.size() * 96);
            for (MoveLog.Record r : all) {
                String line = MoveLog.serialize(r);
                if (!line.isEmpty()) {
                    sb.append(line).append('\n');
                }
            }
            OutputStreamWriter w = new OutputStreamWriter(
                    new java.io.FileOutputStream(file(ctx), false), StandardCharsets.UTF_8);
            w.write(sb.toString());
            w.close();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    public static synchronized List<MoveLog.Record> readAll(Context ctx) {
        List<MoveLog.Record> out = new ArrayList<MoveLog.Record>();
        if (ctx == null) {
            return out;
        }
        File f = file(ctx);
        if (!f.exists()) {
            return out;
        }
        BufferedReader r = null;
        try {
            r = new BufferedReader(new InputStreamReader(new FileInputStream(f),
                    StandardCharsets.UTF_8));
            String line;
            while ((line = r.readLine()) != null) {
                MoveLog.Record rec = MoveLog.parse(line);
                if (rec != null) {
                    out.add(rec);
                }
            }
        } catch (Exception ignored) {
        } finally {
            if (r != null) {
                try {
                    r.close();
                } catch (Exception ignored) {
                }
            }
        }
        return out;
    }

    /** 批次列表（倒序，最多 limit 个）。 */
    public static List<MoveLog.Batch> batches(Context ctx, int limit) {
        List<MoveLog.Batch> all = MoveLog.group(readAll(ctx));
        if (limit > 0 && all.size() > limit) {
            return new ArrayList<MoveLog.Batch>(all.subList(0, limit));
        }
        return all;
    }

    /** 某批次的记录（保持原始顺序）。 */
    public static List<MoveLog.Record> targets(Context ctx, String batchId) {
        List<MoveLog.Record> out = new ArrayList<MoveLog.Record>();
        for (MoveLog.Record r : readAll(ctx)) {
            if (r.batchId.equals(batchId)) {
                out.add(r);
            }
        }
        return out;
    }

    /**
     * 撤销一批移动：把文件搬回原目录原名。
     *
     * @return {成功, 失败, 总数}
     */
    public static int[] revert(Storage st, Context ctx, String batchId, Logger log) {
        List<MoveLog.Record> records = MoveLog.reversed(targets(ctx, batchId));
        if (records.isEmpty()) {
            if (log != null) {
                log.log("没有可撤销的整理记录。", "warning");
            }
            return new int[]{0, 0, 0};
        }
        int ok = 0;
        int failed = 0;
        for (MoveLog.Record r : records) {
            try {
                VFile toDir = st.stat(r.toDir, null);
                VFile file = toDir == null ? null : st.findChild(toDir, r.toName);
                VFile fromDir = st.stat(r.fromDir, null);
                if (file == null || fromDir == null) {
                    failed++;
                    if (log != null && failed <= 5) {
                        log.log("搬回失败：" + r.toName + "（原位置或文件已不在）", "warning");
                    }
                    continue;
                }
                String name = r.fromName.isEmpty() ? file.name : r.fromName;
                if (st.findChild(fromDir, name) != null) {
                    // 原位置被占了（比如又整理出一份）：加序号，别覆盖
                    name = uniqueName(st, fromDir, name);
                }
                if (!name.equals(file.name) && !st.rename(file, name)) {
                    failed++;
                    continue;
                }
                String why = st.moveWithReason(file, fromDir);
                if (why == null) {
                    ok++;
                    Scanner.invalidate(file);
                } else {
                    failed++;
                    if (log != null && failed <= 5) {
                        log.log("搬回失败：" + name + "（" + why + "）", "error");
                    }
                }
            } catch (Exception e) {
                failed++;
            }
        }
        if (log != null) {
            log.log("撤销整理：搬回 " + ok + " 个" + (failed > 0 ? "，失败 " + failed + " 个" : ""),
                    failed > 0 ? "warning" : "success");
        }
        return new int[]{ok, failed, records.size()};
    }

    private static String uniqueName(Storage st, VFile dir, String name) {
        String stem = name;
        String ext = "";
        int dot = name.lastIndexOf('.');
        if (dot > 0) {
            stem = name.substring(0, dot);
            ext = name.substring(dot);
        }
        for (int i = 1; i < 1000; i++) {
            String candidate = stem + " (" + i + ")" + ext;
            if (st.findChild(dir, candidate) == null) {
                return candidate;
            }
        }
        return name;
    }
}
