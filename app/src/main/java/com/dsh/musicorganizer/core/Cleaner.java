package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 文件名清理与空目录管理 —— 对应 Python 版 plan_cleanup / execute_cleanup /
 * delete_empty_dirs_loop / plan_empty_dirs / flatten_directory。
 */
public final class Cleaner {

    private Cleaner() {
    }

    public static class RenamePlan {
        public final VFile source;
        public final String newStem;
        public final String status; // ok / unchanged / conflict
        public final String reason;

        public RenamePlan(VFile source, String newStem, String status, String reason) {
            this.source = source;
            this.newStem = newStem;
            this.status = status;
            this.reason = reason;
        }

        public String targetName() {
            return newStem + source.ext();
        }
    }

    /** 生成重命名计划（不改盘）。 */
    public static List<RenamePlan> planCleanup(Storage st, List<VFile> files) {
        List<RenamePlan> plans = new ArrayList<RenamePlan>();
        Set<String> reserved = new HashSet<String>();
        for (VFile f : files) {
            String stem = f.stem();
            String newStem = TextUtil.normalizeStemForCleanup(stem);
            if (newStem.equals(stem)) {
                plans.add(new RenamePlan(f, stem, "unchanged", ""));
                continue;
            }
            String targetKey = (f.parentId + "/" + newStem + f.ext()).toLowerCase();
            VFile parentDir = dirOf(st, f);
            boolean targetExists = parentDir != null
                    && st.findChild(parentDir, newStem + f.ext()) != null;
            if (reserved.contains(targetKey)) {
                plans.add(new RenamePlan(f, newStem, "conflict", "目标名与本次另一文件重复"));
            } else if (targetExists) {
                plans.add(new RenamePlan(f, newStem, "conflict", "目标文件已存在"));
            } else {
                plans.add(new RenamePlan(f, newStem, "ok", ""));
            }
            reserved.add(targetKey);
        }
        return plans;
    }

    private static VFile dirOf(Storage st, VFile f) {
        VFile dir = st.stat(f.parentId, null);
        return dir;
    }

    /** 执行重命名计划，返回 {renamed, conflict, error}。 */
    public static int[] execute(List<RenamePlan> plans, Logger log) {
        int renamed = 0;
        int conflict = 0;
        int error = 0;
        for (RenamePlan plan : plans) {
            if (plan.status.equals("unchanged")) {
                continue;
            }
            if (plan.status.equals("conflict")) {
                conflict++;
                continue;
            }
            if (st_rename(plan, log)) {
                renamed++;
            } else {
                error++;
            }
        }
        return new int[]{renamed, conflict, error};
    }

    private static boolean st_rename(RenamePlan plan, Logger log) {
        boolean ok = plan.source != null
                && DirOps.rename(plan.source, plan.targetName());
        if (!ok && log != null) {
            log.log("重命名失败：" + plan.source.name, "error");
        }
        return ok;
    }

    /** 预览空目录；未识别目录单独列出。 */
    public static class EmptyDirs {
        public final List<VFile> empty = new ArrayList<VFile>();
        public final List<VFile> protectedDirs = new ArrayList<VFile>();
    }

    public static EmptyDirs planEmptyDirs(Storage st, VFile root, CancelToken cancel) {
        EmptyDirs out = new EmptyDirs();
        collectEmpty(st, root, root, out, cancel);
        return out;
    }

    private static void collectEmpty(Storage st, VFile root, VFile dir,
                                     EmptyDirs out, CancelToken cancel) {
        if (cancel != null && cancel.isCancelled()) {
            return;
        }
        for (VFile c : st.children(dir)) {
            if (!c.dir) {
                continue;
            }
            collectEmpty(st, root, c, out, cancel);
            if (st.children(c).isEmpty()) {
                if (c.name.equalsIgnoreCase(TextUtil.UNRECOGNIZED_DIR)
                        && c.parentId != null && c.parentId.equals(root.docId)) {
                    out.protectedDirs.add(c);
                } else {
                    out.empty.add(c);
                }
            }
        }
    }

    /** 循环删除空子目录直到稳定；未识别目录受保护；根目录不删。返回删除数。 */
    public static int deleteEmptyDirs(Storage st, VFile root, CancelToken cancel) {
        int total = 0;
        while (true) {
            int removedThisRound = 0;
            EmptyDirs plan = planEmptyDirs(st, root, cancel);
            for (VFile dir : plan.empty) {
                if (cancel != null && cancel.isCancelled()) {
                    return total;
                }
                if (st.delete(dir)) {
                    removedThisRound++;
                }
            }
            total += removedThisRound;
            if (removedThisRound == 0) {
                break;
            }
        }
        return total;
    }

    /** 删除文件（未识别目录内的文件受保护）。 */
    public static boolean deleteFile(VFile root, VFile file) {
        if (file.parentId != null && file.parentId.equals(root.docId)
                && file.name.equalsIgnoreCase(TextUtil.UNRECOGNIZED_DIR)) {
            return false;
        }
        return DirOps.delete(file);
    }

    // ------------------------------------------------------------------
    // 扁平化目录（flatten_directory，对应 Python 版）
    // ------------------------------------------------------------------

    /** 一条「扁平化」移动计划：把某个子目录里的文件搬到根目录。 */
    public static class FlattenPlan {
        public final VFile source;
        /** 搬到根目录后的最终文件名（与根目录已有文件撞名时带 _2 / _3 后缀）。 */
        public final String targetName;
        /** 源文件当前所在的相对目录（预览用，如「Music/周杰伦」）。 */
        public final String fromDir;
        public boolean selected = true;

        FlattenPlan(VFile source, String targetName, String fromDir) {
            this.source = source;
            this.targetName = targetName;
            this.fromDir = fromDir;
        }

        /** 需要改名（避开根目录重名）时才非空。 */
        public boolean renamed() {
            return !targetName.equals(source.name);
        }
    }

    /**
     * 生成「扁平化」计划（不改盘）：把根目录下所有嵌套子目录里的音频 / 歌词
     * 移动到根目录这一层。已在根目录的文件跳过；与根目录已有文件撞名时，
     * 在基本名后加 {@code _2}、{@code _3}… 避开。
     */
    public static List<FlattenPlan> planFlatten(Storage st, VFile root, CancelToken cancel) {
        List<VFile> files = Scanner.walkMusic(st, root, true, null, cancel);
        Set<String> taken = new HashSet<String>();
        for (VFile f : files) {
            if (f.parentId != null && f.parentId.equals(root.docId)) {
                taken.add(f.name.toLowerCase());
            }
        }
        List<FlattenPlan> plans = new ArrayList<FlattenPlan>();
        for (VFile f : files) {
            if (cancel != null && cancel.isCancelled()) {
                break;
            }
            if (f.dir) {
                continue;
            }
            if (f.parentId != null && f.parentId.equals(root.docId)) {
                continue; // 已经在根目录
            }
            String name = f.name;
            String lower = name.toLowerCase();
            if (taken.contains(lower)) {
                name = uniqueName(name, taken);
            }
            taken.add(name.toLowerCase());
            plans.add(new FlattenPlan(f, name, relativeDirOf(st, root, f)));
        }
        return plans;
    }

    private static String uniqueName(String name, Set<String> taken) {
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 2; ; i++) {
            String candidate = stem + "_" + i + ext;
            if (!taken.contains(candidate.toLowerCase())) {
                return candidate;
            }
        }
    }

    private static String relativeDirOf(Storage st, VFile root, VFile f) {
        String path = f.pathAfterRoot();
        int slash = path.lastIndexOf('/');
        return slash > 0 ? path.substring(0, slash) : "";
    }

    /**
     * 执行扁平化：只移动勾选的；移动完成后删除空出来的子目录。
     * 返回 {@code {moved, error, removedDirs}}。
     */
    public static int[] executeFlatten(Storage st, VFile root, List<FlattenPlan> plans,
                                       Logger log, CancelToken cancel) {
        int moved = 0;
        int error = 0;
        for (FlattenPlan p : plans) {
            if (cancel != null && cancel.isCancelled()) {
                break;
            }
            if (!p.selected) {
                continue;
            }
            VFile src = p.source;
            // 撞名时先在源目录内改名，再移动；改名失败就用原名直接移动（可能覆盖失败）
            if (!p.targetName.equals(src.name)) {
                VFile parent = st.stat(src.parentId, null);
                if (parent != null && st.rename(src, p.targetName)) {
                    src = st.findChild(parent, p.targetName);
                }
            }
            if (src != null && st.move(src, root)) {
                moved++;
            } else {
                error++;
                if (log != null) {
                    log.log("扁平化移动失败：" + p.source.name, "error");
                }
            }
        }
        int removedDirs = deleteEmptyDirs(st, root, cancel);
        return new int[]{moved, error, removedDirs};
    }

    /** 目录操作统一入口（便于测试替身）。 */
    static final class DirOps {
        static boolean rename(VFile f, String newName) {
            return Storage.renameStatic(f, newName);
        }

        static boolean delete(VFile f) {
            return Storage.deleteStatic(f);
        }
    }
}
