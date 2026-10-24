package com.dsh.musicorganizer.core;

import android.content.ContentResolver;
import android.content.Context;

import java.io.File;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * 标签事务写入 —— 对应 Python 版 TagEditPlan / execute_plan。
 *
 * 流程（R-04：任何标签写入必须走本类）：
 *   before 快照 → 复制到本地缓存副本 → 在副本上写 → 读回校验
 *   → 备份当前原文件 → 写回 SAF → 回读校验（失败自动用备份恢复）
 *   → journal 追加 applied 记录。
 */
public final class TagTransaction {

    private TagTransaction() {
    }

    /** 读取 SAF 文件标签（复制到缓存再解析 + MMR 兜底）。 */
    public static Tags read(Storage st, ContentResolver resolver, VFile f) {
        return Scanner.readTagsCheap(st, resolver, f);
    }

    /**
     * 应用字段更新。updates 只包含要修改的字段（空字符串表示清除）。
     * 返回 "" 表示成功，否则为错误信息（原文件保证未被修改）。
     */
    public static String apply(Storage st, ContentResolver resolver, Context ctx,
                               VFile f, Map<String, String> updates,
                               boolean record, String batchId, Logger log) {
        return applyInternal(st, resolver, ctx, f, updates, null, record, batchId, log);
    }

    /**
     * 写入封面（不改文本字段）。走同一套事务：副本写入 → 校验 → 备份 → 写回 → 回读。
     *
     * @param cover 图片字节；长度为 0 表示删除封面
     */
    public static String applyCover(Storage st, ContentResolver resolver, Context ctx,
                                    VFile f, byte[] cover, Logger log) {
        if (cover == null) {
            return "无变更，跳过写入";
        }
        return applyInternal(st, resolver, ctx, f,
                new HashMap<String, String>(), cover, false, "", log);
    }

    /**
     * 字段 + 封面一次写入（单文件编辑器用）。
     *
     * <p>分成两次 {@code apply} 就要复制文件两遍、写两遍；这里走同一条事务，
     * 一次副本同时改文本帧和图片块，校验也一起做。
     *
     * @param updates 文本字段（可为空 map）
     * @param cover   null = 不动封面；长度 0 = 删除；否则替换
     */
    public static String applyWithCover(Storage st, ContentResolver resolver, Context ctx,
                                        VFile f, Map<String, String> updates, byte[] cover,
                                        boolean record, String batchId, Logger log) {
        return applyInternal(st, resolver, ctx, f, updates, cover, record, batchId, log);
    }

    private static String applyInternal(Storage st, ContentResolver resolver, Context ctx,
                                        VFile f, Map<String, String> updates, byte[] cover,
                                        boolean record, String batchId, Logger log) {
        if (updates == null) {
            updates = new HashMap<String, String>();
        }
        if (updates.isEmpty() && cover == null) {
            return "无变更，跳过写入";
        }
        if (!TagIO.canWrite(TagIO.extOf(f.name))) {
            String msg = TagIO.writeLocal(new File("probe" + TagIO.extOf(f.name)),
                    new HashMap<String, String>());
            return msg.isEmpty() ? "该格式不支持写标签" : msg;
        }
        Tags before = read(st, resolver, f);
        if (before == null) {
            return "无法读取原标签";
        }

        File tmp = null;
        File backup = null;
        try {
            // 1. 副本
            tmp = File.createTempFile("mo_write_", TagIO.extOf(f.name));
            st.copyToLocal(f, tmp);

            // 2. 在副本上写
            String err = TagIO.writeLocal(tmp, updates, cover);
            if (!err.isEmpty()) {
                return "标签写入失败（原文件未修改）：" + err;
            }

            // 3. 副本校验
            Tags verify = TagIO.readLocal(tmp);
            for (Map.Entry<String, String> e : updates.entrySet()) {
                if (!verify.get(e.getKey()).equals(e.getValue().trim())) {
                    return "字段校验失败（原文件未修改）：" + Tags.LABELS.get(e.getKey());
                }
            }
            if (cover != null) {
                boolean want = cover.length > 0;
                if (TagIO.hasCoverLocal(tmp) != want) {
                    return "封面校验失败（原文件未修改）";
                }
            }

            // 4. 备份当前原文件
            backup = File.createTempFile("mo_backup_", TagIO.extOf(f.name));
            st.copyToLocal(f, backup);

            // 5. 写回 SAF
            st.writeFromLocal(f, tmp);

            // 6. 回读校验，失败则恢复备份
            //    先丢掉这个文件的旧缓存：VFile 的 size/lastModified 是 final，写入后对象里仍是
            //    写入前的快照，而缓存键正是 docId|size|lastModified —— 不清就会读到旧标签，
            //    校验必然失败（历史 bug：整批 110 首全被判成写不进去）。
            Scanner.invalidate(f);
            Tags after = read(st, resolver, f);
            for (Map.Entry<String, String> e : updates.entrySet()) {
                if (!after.get(e.getKey()).equals(e.getValue().trim())) {
                    st.writeFromLocal(f, backup);
                    Scanner.invalidate(f);
                    return "回读校验失败，已从备份恢复：" + Tags.LABELS.get(e.getKey());
                }
            }
            if (cover != null && !updates.isEmpty()) {
                // 字段和封面一起写时，回读确认封面也在（只有封面时缓存不涉及，跳过）
                Scanner.invalidate(f);
            }

            // 7. journal（只有封面变更时不记：回滚只能回滚字段）
            if (record && ctx != null && !updates.isEmpty()) {
                Journal.Entry entry = new Journal.Entry();
                entry.id = System.currentTimeMillis() + "-" + f.name;
                entry.timestamp = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
                        .format(new Date());
                entry.uri = f.docId;
                entry.name = f.name;
                entry.batchId = batchId == null ? "" : batchId;
                for (String k : Tags.KEYS) {
                    entry.before.put(k, before.get(k));
                    entry.after.put(k, after.get(k));
                }
                entry.status = "applied";
                if (!Journal.append(ctx, entry) && log != null) {
                    log.log("写入成功但 journal 记录失败：" + f.name, "warning");
                }
            }
            if (log != null) {
                log.log(updates.isEmpty() ? "封面写入成功：" + f.name : "标签写入成功：" + f.name,
                        "success");
            }
            Scanner.invalidate(f);
            return "";
        } catch (Exception e) {
            return "写入失败（原文件未修改）：" + TextUtil.shortError(e);
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
            if (backup != null) {
                //noinspection ResultOfMethodCallIgnored
                backup.delete();
            }
        }
    }

    /** 撤销最近一次标签写入。 */
    public static boolean revertLast(Storage st, ContentResolver resolver, Context ctx,
                                     Logger log) {
        Journal.Entry entry = Journal.findLastApplied(ctx);
        if (entry == null) {
            if (log != null) {
                log.log("没有可撤销的写入记录。", "warning");
            }
            return false;
        }
        return revertOne(st, resolver, ctx, entry, log);
    }

    /**
     * 撤销最近一次写入所属的**整批**（批量打标签 N 首都共用一个 batchId）。
     * 非批量写入（batchId 为空）时等价于 revertLast。
     *
     * @return {reverted, failed, total}
     */
    public static int[] revertLastBatch(Storage st, ContentResolver resolver, Context ctx,
                                        Logger log) {
        Journal.Entry last = Journal.findLastApplied(ctx);
        if (last == null) {
            if (log != null) {
                log.log("没有可撤销的写入记录。", "warning");
            }
            return new int[]{0, 0, 0};
        }
        return revertBatch(st, resolver, ctx, JournalHistory.keyOf(rowOf(last)), log);
    }

    /**
     * 撤销指定批次（「撤销历史」里选中的那一批）。
     *
     * @param key {@link JournalHistory#keyOf} 得到的批次键
     * @return {reverted, failed, total}
     */
    public static int[] revertBatch(Storage st, ContentResolver resolver, Context ctx,
                                    String key, Logger log) {
        List<Journal.Entry> targets = Journal.targets(ctx, key);
        if (targets.isEmpty()) {
            if (log != null) {
                log.log("该批次已全部撤销或记录不存在。", "warning");
            }
            return new int[]{0, 0, 0};
        }
        int ok = 0;
        int failed = 0;
        // 逆序回滚：后写的先撤，避免中途失败时状态更乱
        for (int i = targets.size() - 1; i >= 0; i--) {
            if (revertOne(st, resolver, ctx, targets.get(i), null)) {
                ok++;
            } else {
                failed++;
            }
        }
        if (log != null) {
            log.log("撤销批次：成功 " + ok + " 首" + (failed > 0 ? "，失败 " + failed + " 首" : ""),
                    failed > 0 ? "warning" : "success");
        }
        return new int[]{ok, failed, targets.size()};
    }

    private static JournalHistory.Row rowOf(Journal.Entry e) {
        JournalHistory.Row r = new JournalHistory.Row();
        r.id = e.id;
        r.batchId = e.batchId;
        r.timestamp = e.timestamp;
        r.uri = e.uri;
        r.status = e.status;
        r.targetId = e.targetId;
        r.name = e.name;
        return r;
    }

    /** 回滚单条 journal 记录（不改动原记录状态，另追加一条 reverted）。 */
    private static boolean revertOne(Storage st, ContentResolver resolver, Context ctx,
                                     Journal.Entry entry, Logger log) {
        Map<String, String> updates = new HashMap<String, String>();
        boolean has = false;
        for (String k : Tags.KEYS) {
            String oldV = entry.before.get(k);
            String newV = entry.after.get(k);
            if (oldV != null && newV != null && !oldV.equals(newV)) {
                updates.put(k, oldV);
                has = true;
            }
        }
        if (!has) {
            return false;
        }
        VFile target = findByDocId(st, entry.uri);
        if (target == null) {
            if (log != null) {
                log.log("找不到原文件：" + entry.uri, "error");
            }
            return false;
        }
        String err = apply(st, resolver, ctx, target, updates, false, "", log);
        if (!err.isEmpty()) {
            if (log != null) {
                log.log("撤销失败：" + err, "error");
            }
            return false;
        }
        Journal.Entry revertEntry = new Journal.Entry();
        revertEntry.id = System.currentTimeMillis() + "-revert-" + entry.id;
        revertEntry.timestamp = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
                .format(new Date());
        revertEntry.uri = entry.uri;
        revertEntry.name = target.name;
        revertEntry.batchId = entry.batchId;
        revertEntry.status = "reverted";
        revertEntry.targetId = entry.id;
        Journal.append(ctx, revertEntry);
        if (log != null) {
            log.log("撤销成功：" + target.name, "success");
        }
        return true;
    }

    private static VFile findByDocId(Storage st, String docId) {
        VFile f = st.stat(docId, null);
        return f;
    }
}
