package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 文件名查重 —— 对应 Python 版 find_duplicate_groups（UnionFind + bigram 倒排）。
 */
public final class Duplicates {

    private Duplicates() {
    }

    private static final Pattern COPY_SUFFIX_RE = Pattern.compile(
            "(?:\\s*[（(]\\s*\\d+\\s*[)）]|\\s*[-_ ]\\s*(?:副本|拷贝|copy|複製|复制)\\s*\\d*)*$",
            Pattern.CASE_INSENSITIVE);

    /** 判断「这个名字是否带复制痕迹」用；不能直接用 {@link #COPY_SUFFIX_RE}，它会匹配空串。 */
    private static final Pattern COPY_MARK_RE = Pattern.compile(
            "[（(]\\s*\\d+\\s*[)）]|[-_ ]\\s*(?:副本|拷贝|copy|複製|复制)\\s*\\d*\\s*$",
            Pattern.CASE_INSENSITIVE);

    public static String normalizeDuplicateKey(String stem) {
        String text = TextUtil.stripTrailingNumericSuffix(stem == null ? "" : stem);
        text = TextUtil.toSimplified(text).toLowerCase();
        text = COPY_SUFFIX_RE.matcher(text).replaceFirst("");
        text = text.replaceAll("\\s+", "");
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (Character.isLetterOrDigit(c)) {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    private static Set<String> bigrams(String text) {
        Set<String> out = new HashSet<String>();
        if (text.length() < 2) {
            out.add(text);
            return out;
        }
        for (int i = 0; i + 2 <= text.length(); i++) {
            out.add(text.substring(i, i + 2));
        }
        return out;
    }

    public static class Item {
        public final VFile file;
        public final String relative;
        public final long size;
        public Double duration;

        public Item(VFile file, String relative, long size, Double duration) {
            this.file = file;
            this.relative = relative;
            this.size = size;
            this.duration = duration;
        }
    }

    public static class Group {
        public final List<Item> files = new ArrayList<Item>();
        public final String key;
        /** 组内最高相似度（1.0 表示归一后完全相同，可能只差「(1)」「副本」这类尾巴） */
        public double score = 1.0;

        public Group(String key) {
            this.key = key;
        }

        /** 这一组最多能省多少空间（全部删掉只剩一个）。 */
        public long wastedBytes() {
            long total = 0;
            for (Item it : files) {
                total += it.size;
            }
            int keep = recommendKeep(this);
            long keepSize = keep >= 0 ? files.get(keep).size : 0;
            return Math.max(0, total - keepSize);
        }
    }

    /**
     * 建议保留哪一个（{@code -1} 表示没有明显更优的）。
     *
     * <p>规则按优先级：① 名字里没有「(1)」「副本」「copy」这类复制痕迹；
     * ② 体积更大（更可能是完整转码而非截断文件）；③ 路径更短（少一层
     * {@code Music/新建文件夹/} 这类中间目录）。都不相同时取第一个。
     */
    public static int recommendKeep(Group group) {
        if (group == null || group.files.isEmpty()) {
            return -1;
        }
        int best = 0;
        double bestScore = -1;
        long maxSize = 1;
        for (Item it : group.files) {
            maxSize = Math.max(maxSize, it.size);
        }
        for (int i = 0; i < group.files.size(); i++) {
            Item it = group.files.get(i);
            double score = 0;
            if (!COPY_MARK_RE.matcher(it.file.stem() == null ? "" : it.file.stem()).find()) {
                score += 1.0;
            }
            score += 0.40 * (it.size / (double) maxSize);
            score -= 0.20 * Math.min(1.0, it.relative.length() / 120.0);
            if (score > bestScore) {
                bestScore = score;
                best = i;
            }
        }
        return best;
    }

    /** 摘要文案：「3 组 · 5 个多余文件 · 约 12.3 MB」，供对话框与日志复用。 */
    public static String summary(List<Group> groups) {
        if (groups == null || groups.isEmpty()) {
            return "没有发现相似文件";
        }
        long wasted = 0;
        int extra = 0;
        for (Group g : groups) {
            extra += Math.max(0, g.files.size() - 1);
            wasted += g.wastedBytes();
        }
        return groups.size() + " 组 · " + extra + " 个多余文件 · 约 "
                + TextUtil.formatSize(wasted);
    }

    private static class UnionFind {
        private final int[] parent;
        private final int[] rank;

        UnionFind(int size) {
            parent = new int[size];
            rank = new int[size];
            for (int i = 0; i < size; i++) {
                parent[i] = i;
            }
        }

        int find(int x) {
            while (parent[x] != x) {
                parent[x] = parent[parent[x]];
                x = parent[x];
            }
            return x;
        }

        void union(int a, int b) {
            int ra = find(a);
            int rb = find(b);
            if (ra == rb) {
                return;
            }
            if (rank[ra] < rank[rb]) {
                int t = ra;
                ra = rb;
                rb = t;
            }
            parent[rb] = ra;
            if (rank[ra] == rank[rb]) {
                rank[ra]++;
            }
        }
    }

    /**
     * 查找相似文件名分组。threshold 与 Python 版一致：完全相同或相似度 ≥ 0.90。
     */
    public static List<Group> find(List<VFile> audioFiles, String rootDocId,
                                   Progress progress, CancelToken cancel) {
        int total = audioFiles.size();
        if (total == 0) {
            return new ArrayList<Group>();
        }
        if (progress != null) {
            progress.onProgress(0, total, "已找到 " + total + " 个音频文件，正在比较文件名");
        }
        List<String> keys = new ArrayList<String>(total);
        for (int i = 0; i < total; i++) {
            keys.add(normalizeDuplicateKey(audioFiles.get(i).stem()));
        }

        UnionFind uf = new UnionFind(total);
        Map<String, List<Integer>> byKey = new HashMap<String, List<Integer>>();
        for (int i = 0; i < total; i++) {
            if (!keys.get(i).isEmpty()) {
                List<Integer> list = byKey.get(keys.get(i));
                if (list == null) {
                    list = new ArrayList<Integer>();
                    byKey.put(keys.get(i), list);
                }
                list.add(i);
            }
        }
        for (List<Integer> list : byKey.values()) {
            for (int j = 1; j < list.size(); j++) {
                uf.union(list.get(0), list.get(j));
            }
        }

        Map<String, List<Integer>> inverted = new HashMap<String, List<Integer>>();
        for (int i = 0; i < total; i++) {
            String key = keys.get(i);
            if (key.length() < 3) {
                continue;
            }
            for (String gram : bigrams(key)) {
                List<Integer> list = inverted.get(gram);
                if (list == null) {
                    list = new ArrayList<Integer>();
                    inverted.put(gram, list);
                }
                list.add(i);
            }
        }

        Set<Long> compared = new HashSet<Long>();
        for (int i = 0; i < total; i++) {
            if (cancel != null && cancel.isCancelled()) {
                return new ArrayList<Group>();
            }
            if (progress != null && i % 25 == 0) {
                progress.onProgress(i, total, "正在比较相似文件名");
            }
            String key = keys.get(i);
            if (key.length() < 3) {
                continue;
            }
            Set<Integer> candidates = new HashSet<Integer>();
            for (String gram : bigrams(key)) {
                List<Integer> list = inverted.get(gram);
                if (list != null) {
                    int limit = Math.min(list.size(), 400);
                    for (int j = 0; j < limit; j++) {
                        candidates.add(list.get(j));
                    }
                }
            }
            int count = 0;
            List<Integer> sorted = new ArrayList<Integer>(candidates);
            java.util.Collections.sort(sorted);
            for (int other : sorted) {
                if (other == i) {
                    continue;
                }
                long pair = i < other ? ((long) i << 32) | other : ((long) other << 32) | i;
                if (compared.contains(pair)) {
                    continue;
                }
                compared.add(pair);
                String otherKey = keys.get(other);
                if (otherKey.isEmpty()) {
                    continue;
                }
                int minLen = Math.min(key.length(), otherKey.length());
                int maxLen = Math.max(key.length(), otherKey.length());
                if (minLen == 0 || minLen / (double) maxLen < 0.58) {
                    continue;
                }
                if (key.equals(otherKey)) {
                    uf.union(i, other);
                    continue;
                }
                if (TextUtil.ratio(key, otherKey) >= 0.90) {
                    uf.union(i, other);
                }
                count++;
                if (count >= 500) {
                    break;
                }
            }
        }

        Map<Integer, Group> clusters = new HashMap<Integer, Group>();
        for (int i = 0; i < total; i++) {
            int root = uf.find(i);
            Group group = clusters.get(root);
            if (group == null) {
                group = new Group(keys.get(i));
                clusters.put(root, group);
            }
            VFile f = audioFiles.get(i);
            group.files.add(new Item(f, f.pathAfterRoot(), f.size, null));
        }
        List<Group> out = new ArrayList<Group>();
        for (Group group : clusters.values()) {
            if (group.files.size() >= 2) {
                group.score = groupScore(group);
                out.add(group);
            }
        }
        // 稳定排序：先按「组内文件多」再按省下的空间，最后按名字，界面顺序不会每次乱跳
        java.util.Collections.sort(out, new java.util.Comparator<Group>() {
            @Override
            public int compare(Group a, Group b) {
                if (a.files.size() != b.files.size()) {
                    return b.files.size() - a.files.size();
                }
                long wa = a.wastedBytes();
                long wb = b.wastedBytes();
                if (wa != wb) {
                    return wa > wb ? -1 : 1;
                }
                return a.key.compareTo(b.key);
            }
        });
        if (progress != null) {
            progress.onProgress(1, 1, "扫描完成：发现 " + out.size() + " 个相似组");
        }
        return out;
    }

    /** 组内最高相似度（两两比较，组一般只有两三个文件，代价可忽略）。 */
    private static double groupScore(Group group) {
        double best = 0;
        for (int i = 0; i < group.files.size(); i++) {
            String a = normalizeDuplicateKey(group.files.get(i).file.stem());
            for (int j = i + 1; j < group.files.size(); j++) {
                String b = normalizeDuplicateKey(group.files.get(j).file.stem());
                if (a.equals(b)) {
                    return 1.0;
                }
                double s = TextUtil.ratio(a, b);
                if (s > best) {
                    best = s;
                }
            }
        }
        return best;
    }
}
