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

    /**
     * 「确证」档门槛：相似度 ≥ 0.95 且不依赖「包含度兜底」的组。
     *
     * <p>低于它的不丢，只是标「疑似」并默认不勾选 —— 查重是提示，误删是不可逆的。
     */
    public static final double HIGH_CONFIDENCE = 0.95;

    private Duplicates() {
    }

    /**
     * 读音频时长（秒）；返回 0 表示读不到。
     *
     * <p>只在「短名被长名完整包含」这种最容易误判的情况下才调用，实现方应自行缓存 ——
     * 一次查重里同一首可能被问好几次。
     */
    public interface DurationSource {
        double durationOf(VFile file);

        /**
         * 内嵌标签里的艺人（v0.1.86）；返回空串表示读不到/没有标签。
         *
         * <p>为什么要它：文件名常常是「歌名(1)」「歌名」这种不带艺人的写法，
         * 而同一首歌有无数翻唱版本。只看文件名会把「不同歌手唱同名歌」判成重复，
         * 读一眼内嵌标签就能区分。默认实现返回空串，纯逻辑测试不必实现。
         */
        default String tagArtist(VFile file) {
            return "";
        }
    }

    private static final Pattern COPY_SUFFIX_RE = Pattern.compile(
            "(?:\\s*[（(]\\s*\\d+\\s*[)）]|\\s*[-_ ]\\s*(?:副本|拷贝|copy|複製|复制)\\s*\\d*)*$",
            Pattern.CASE_INSENSITIVE);

    /** 判断「这个名字是否带复制痕迹」用；不能直接用 {@link #COPY_SUFFIX_RE}，它会匹配空串。 */
    private static final Pattern COPY_MARK_RE = Pattern.compile(
            "[（(]\\s*\\d+\\s*[)）]|[-_ ]\\s*(?:副本|拷贝|copy|複製|复制)\\s*\\d*\\s*$",
            Pattern.CASE_INSENSITIVE);

    /** 相似度门槛：完全相同或 ≥ 0.90 即成组。 */
    private static final double THRESHOLD = 0.90;
    /** 整串比较前的长度比门槛：差太多根本不必算相似度（省时间，也避免长串包含短串误判）。 */
    private static final double MIN_LEN_RATIO = 0.58;
    /** 两个艺人名算「同一个人」的门槛：低于它视为不同歌手（含翻唱）。 */
    private static final double ARTIST_SAME = 0.80;

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

    /**
     * 只留歌名的归一键。
     *
     * <p>「陈奕迅-十年」→{@code 十年}；解析不出艺人时等价于整串归一。
     * 查重真正要比的是歌名，艺人只是同一首歌的额外信息。
     */
    public static String titleKeyOf(String stem) {
        String s = stem == null ? "" : stem;
        NameParser.Split split = NameParser.splitArtistTitle(s);
        String title = split == null ? NameParser.stripNameNoise(s) : split.right;
        return normalizeDuplicateKey(title);
    }

    /** 只留艺人的归一键；解析不出艺人时返回空串。 */
    public static String artistKeyOf(String stem) {
        NameParser.Split split = NameParser.splitArtistTitle(stem == null ? "" : stem);
        return split == null ? "" : normalizeDuplicateKey(split.left);
    }

    /** 整串比较前的长度比门槛（标题比较不走这道门，标题本来就短）。 */
    private static boolean lengthGateOk(String a, String b) {
        int min = Math.min(a.length(), b.length());
        int max = Math.max(a.length(), b.length());
        return min > 0 && min / (double) max >= MIN_LEN_RATIO;
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
        /**
         * 疑似：要么相似度落在 [0.90, 0.95)，要么靠「短名被长名包含」达成命中但读不到时长。
         *
         * <p>界面据此默认不勾选，让用户先确认再删。
         */
        public boolean suspect;

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

    /** 摘要文案：「3 组 · 5 个多余文件 · 约 12.3 MB」，有疑似组时一并说明。 */
    public static String summary(List<Group> groups) {
        if (groups == null || groups.isEmpty()) {
            return "没有发现相似文件";
        }
        long wasted = 0;
        int extra = 0;
        int suspect = 0;
        for (Group g : groups) {
            extra += Math.max(0, g.files.size() - 1);
            wasted += g.wastedBytes();
            if (g.suspect) {
                suspect++;
            }
        }
        String head = suspect > 0
                ? groups.size() + " 组（其中 " + suspect + " 组疑似）"
                : groups.size() + " 组";
        return head + " · " + extra + " 个多余文件 · 约 " + TextUtil.formatSize(wasted);
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
     * 查找相似文件名分组（不读时长，包含度命中一律按「疑似」处理）。
     *
     * <p>保留这个签名是为了纯逻辑测试与不带 Storage 的调用方。
     */
    public static List<Group> find(List<VFile> audioFiles, String rootDocId,
                                   Progress progress, CancelToken cancel) {
        return find(audioFiles, rootDocId, progress, cancel, null);
    }

    /**
     * 查找相似文件名分组。完全相同或相似度 ≥ 0.90 即成组。
     *
     * <p><b>为什么用综合相似度而不是纯编辑距离</b>：带艺人前缀的文件名
     * （{@code 艺人-歌名} 与 {@code 歌名}）编辑距离永远差好几个字，
     * 纯 Levenshtein 只有 0.6 上下，等于「只要写了艺人就查不出来」。
     * 综合相似度里的「包含度」能识别出「短名整个出现在长名里」，这正是同曲不同命名的典型形态。
     *
     * <p><b>但包含度会误伤前缀延长的不同歌</b>（{@code 歌名} 与 {@code 歌名加长版} 也可能到 0.90），
     * 所以包含度单独命中时要求时长对得上（差 ≤3s 或 ≤2%）；读不到时长就并组但标
     * {@link Group#suspect}，界面默认不勾选。
     */
    public static List<Group> find(List<VFile> audioFiles, String rootDocId,
                                   Progress progress, CancelToken cancel,
                                   final DurationSource durations) {
        int total = audioFiles.size();
        if (total == 0) {
            return new ArrayList<Group>();
        }
        if (progress != null) {
            progress.onProgress(0, total, "已找到 " + total + " 个音频文件，正在比较文件名");
        }
        List<String> keys = new ArrayList<String>(total);
        // 标题键：把「艺人-歌名」里的艺人剥掉，只留歌名。
        // 不这么做的话「陈奕迅-十年」与「十年」长度比只有 0.4，在比相似度之前就被
        // 0.58 的长度门槛刷掉 —— 这是「带艺人前缀就查不出重复」的另一半原因。
        List<String> titleKeys = new ArrayList<String>(total);
        List<String> artistKeys = new ArrayList<String>(total);
        List<String> rawStems = new ArrayList<String>(total);
        for (int i = 0; i < total; i++) {
            String stem = audioFiles.get(i).stem();
            rawStems.add(stem == null ? "" : stem);
            keys.add(normalizeDuplicateKey(stem));
            titleKeys.add(titleKeyOf(stem));
            artistKeys.add(artistKeyOf(stem));
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
            if (key.length() < 2) {
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
        // 靠「包含度」命中但没读到时长的文件：成组后整组标「疑似」
        final boolean[] unknownDuration = new boolean[total];
        final Map<String, Double> durCache = new HashMap<String, Double>();
        final Map<String, String> artistCache = new HashMap<String, String>();
        for (int i = 0; i < total; i++) {
            if (cancel != null && cancel.isCancelled()) {
                return new ArrayList<Group>();
            }
            if (progress != null && i % 25 == 0) {
                progress.onProgress(i, total, "正在比较相似文件名");
            }
            String key = keys.get(i);
            if (key.length() < 2) {
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
                String t1 = titleKeys.get(i);
                String t2 = titleKeys.get(other);
                boolean bothTitles = !t1.isEmpty() && !t2.isEmpty();

                boolean matched;
                boolean containsDriven = false;
                // 名字证据「强」：归一后完全相同（复制尾巴）或歌名一致（艺人前缀）。
                // 这类即使时长对不上也仍然列出来，但标疑似 —— 可能是同一首的剪辑版。
                boolean strongName = false;
                // 艺人信息不全（文件名没写、内嵌标签也没有）时，名字不足以定论，必须靠时长
                boolean needDuration = false;
                if (key.equals(otherKey)) {
                    matched = true;                       // 归一后完全相同：复制件
                    strongName = true;
                } else if (bothTitles && t1.equals(t2)) {
                    // 歌名一致：先看是谁唱的。文件名没写就去读内嵌标签 ——
                    // 同名不同歌手（翻唱）不是重复，这一步就是为它们准备的。
                    String a1 = artistOf(i, artistKeys, artistCache, durations, audioFiles);
                    String a2 = artistOf(other, artistKeys, artistCache, durations, audioFiles);
                    boolean bothArtists = !a1.isEmpty() && !a2.isEmpty();
                    if (bothArtists) {
                        matched = TextUtil.smartSimilarity(a1, a2) >= ARTIST_SAME;
                        strongName = matched;
                    } else {
                        // 有一边不知道是谁：名字不作数，交给时长；读不到时长则列出来标疑似
                        matched = true;
                        strongName = true;
                        needDuration = true;
                    }
                } else {
                    double fullScore = 0;
                    double fullContains = 0;
                    if (lengthGateOk(key, otherKey)) {
                        fullScore = TextUtil.smartSimilarity(key, otherKey);
                        fullContains = TextUtil.containsSimilarity(key, otherKey);
                    }
                    double titleScore = 0;
                    double titleContains = 0;
                    if (bothTitles) {
                        titleScore = TextUtil.smartSimilarity(t1, t2);
                        titleContains = TextUtil.containsSimilarity(t1, t2);
                    }
                    if (Math.max(fullScore, titleScore) < THRESHOLD) {
                        matched = false;
                    } else if (titleScore >= fullScore) {
                        matched = true;
                        containsDriven = titleContains >= THRESHOLD;
                    } else {
                        matched = true;
                        containsDriven = fullContains >= THRESHOLD;
                    }
                }

                if (matched && (strongName || containsDriven || needDuration)) {
                    // 同名同大小的，基本就是一份副本，不做 IO；其余都要拿时长复核 ——
                    // 「歌名 (1)」完全可能是「前后各切掉一段」的剪辑版，光看名字分不出来。
                    boolean identicalCopy = strongName && !needDuration
                            && rawStems.get(i).equals(rawStems.get(other))
                            && audioFiles.get(i).size == audioFiles.get(other).size;
                    if (!identicalCopy) {
                        double d1 = durationOf(durations, durCache, audioFiles.get(i));
                        double d2 = durationOf(durations, durCache, audioFiles.get(other));
                        if (d1 > 0 && d2 > 0) {
                            double tol = Math.max(3.0, Math.max(d1, d2) * 0.02);
                            if (Math.abs(d1 - d2) > tol) {
                                if (needDuration) {
                                    // 艺人信息不全，音频长度又不同 → 大概率是别人翻唱的同一首
                                    matched = false;
                                } else if (strongName) {
                                    // 名字证据强但时长差很多：多半是剪辑版/不同版本，列出但标疑似
                                    unknownDuration[i] = true;
                                    unknownDuration[other] = true;
                                } else {
                                    matched = false;      // 弱证据（包含度）：不同曲，不列
                                }
                            }
                        } else {
                            // 读不到时长：列出来，但不敢默认勾选
                            unknownDuration[i] = true;
                            unknownDuration[other] = true;
                        }
                    }
                }
                if (matched) {
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
            if (unknownDuration[i]) {
                group.suspect = true;
            }
        }
        List<Group> out = new ArrayList<Group>();
        for (Group group : clusters.values()) {
            if (group.files.size() >= 2) {
                // 结果里要显示每个文件的时长，这里统一补齐（能读到的都填上）；
                // 同一首可能已经在判定阶段读过，durCache 会直接命中，不会重复 IO。
                for (Item item : group.files) {
                    if (item.duration == null || item.duration.doubleValue() <= 0) {
                        double d = durationOf(durations, durCache, item.file);
                        if (d > 0) {
                            item.duration = Double.valueOf(d);
                        }
                    }
                }
                group.score = groupScore(group);
                // 相似度没到「确证」档的也标疑似：0.90~0.95 之间确实可能是不同版本
                group.suspect = group.suspect || group.score < HIGH_CONFIDENCE;
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

    /** 组内时长概览：「4:35 / 1:55 · 相差 2:40」；全都读不到时返回空串。 */
    public static String durationSummary(Group group) {
        if (group == null || group.files.isEmpty()) {
            return "";
        }
        StringBuilder text = new StringBuilder();
        double min = Double.MAX_VALUE;
        double max = -1;
        for (Item it : group.files) {
            if (it.duration == null || it.duration.doubleValue() <= 0) {
                continue;
            }
            String one = TextUtil.formatDuration(it.duration.doubleValue());
            if (one.isEmpty()) {
                continue;
            }
            if (text.length() > 0) {
                text.append(" / ");
            }
            text.append(one);
            min = Math.min(min, it.duration.doubleValue());
            max = Math.max(max, it.duration.doubleValue());
        }
        if (text.length() == 0) {
            return "";
        }
        if (max > min) {
            long diff = Math.round(max - min);
            if (diff >= 1) {
                text.append(" · 相差 ").append(TextUtil.formatDuration(Double.valueOf(diff)));
            }
        }
        int known = 0;
        for (Item it : group.files) {
            if (it.duration != null && it.duration.doubleValue() > 0) {
                known++;
            }
        }
        if (known < group.files.size()) {
            text.append("（部分未知）");
        }
        return text.toString();
    }

    /** 组内最高相似度（两两比较，组一般只有两三个文件，代价可忽略）。 */
    private static double groupScore(Group group) {
        double best = 0;
        for (int i = 0; i < group.files.size(); i++) {
            String a = normalizeDuplicateKey(group.files.get(i).file.stem());
            String ta = titleKeyOf(group.files.get(i).file.stem());
            for (int j = i + 1; j < group.files.size(); j++) {
                String b = normalizeDuplicateKey(group.files.get(j).file.stem());
                String tb = titleKeyOf(group.files.get(j).file.stem());
                if (a.equals(b)) {
                    return 1.0;
                }
                // 标题一致（只差艺人前缀）按确证算 —— 这正是「艺人-歌名 / 歌名」的形态；
                // 但两边艺人明确不同（翻唱/重名）不按确证，交给下面的相似度打分
                if (!ta.isEmpty() && ta.equals(tb)) {
                    String aa = artistKeyOf(group.files.get(i).file.stem());
                    String ab = artistKeyOf(group.files.get(j).file.stem());
                    boolean both = !aa.isEmpty() && !ab.isEmpty();
                    if (!both || TextUtil.smartSimilarity(aa, ab) >= 0.80) {
                        return 1.0;
                    }
                }
                // 必须与成组判定用同一个函数，否则界面显示 60% 却已经成组（v0.1.84 修）
                double s = Math.max(TextUtil.smartSimilarity(a, b),
                        TextUtil.smartSimilarity(ta, tb));
                if (s > best) {
                    best = s;
                }
            }
        }
        return best;
    }

    /**
     * 取「这首歌是谁唱的」：文件名里的艺人优先，没有就读内嵌标签。
     *
     * <p>返回已归一的键；空串表示确实不知道。结果按 docId 缓存，同一首只读一次。
     */
    private static String artistOf(int index, List<String> nameArtists, Map<String, String> cache,
                                   DurationSource src, List<VFile> files) {
        String byName = nameArtists.get(index);
        if (byName != null && !byName.isEmpty()) {
            return byName;
        }
        VFile file = files.get(index);
        String key = (file.docId == null || file.docId.isEmpty()) ? file.name : file.docId;
        String cached = cache.get(key);
        if (cached != null) {
            return cached;
        }
        String tag = "";
        try {
            tag = src == null ? "" : TextUtil.safeStr(src.tagArtist(file));
        } catch (Exception ignored) {
            tag = "";
        }
        tag = normalizeDuplicateKey(tag);
        if (isUnknownArtist(tag)) {
            tag = "";
        }
        cache.put(key, tag);
        return tag;
    }

    /** 「群星 / Various Artists / 未知」这类占位艺人等于没写，不能当成一个人去比对。 */
    private static boolean isUnknownArtist(String normalized) {
        if (normalized.isEmpty()) {
            return true;
        }
        String[] placeholders = {
                "群星", "合辑", "未知", "未知艺人", "佚名",
                "various", "variousartists", "unknown", "unknownartist", "va", "ost"};
        for (String p : placeholders) {
            if (p.equals(normalized)) {
                return true;
            }
        }
        return false;
    }

    /** 取时长（带缓存）；来源为 null 或读失败都按「未知」返回 0。 */
    private static double durationOf(DurationSource src, Map<String, Double> cache, VFile file) {
        if (src == null || file == null) {
            return 0;
        }
        String key = (file.docId == null || file.docId.isEmpty()) ? file.name : file.docId;
        Double cached = cache.get(key);
        if (cached != null) {
            return cached.doubleValue();
        }
        double value = 0;
        try {
            value = src.durationOf(file);
        } catch (Exception ignored) {
            value = 0;
        }
        if (value < 0) {
            value = 0;
        }
        cache.put(key, Double.valueOf(value));
        return value;
    }
}
