import com.dsh.musicorganizer.core.DupFiles;

import java.util.ArrayList;
import java.util.List;

/**
 * 重复文件分组回归（纯 JVM，v0.1.58）。
 *
 * <p>覆盖：大小分桶、哈希分组、建议保留哪一份、浪费空间排序、汇总文案。
 */
public class DupFilesTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        bySizeOnlySameSize();
        groupsNeedSameHash();
        suggestKeepShallowest();
        wastedAndOrder();
        summaryText();
        hashOfBytes();
        sampleHashTailMatters();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    /** 1. 只有大小相同的才进候选；0 字节不参与。 */
    static void bySizeOnlySameSize() {
        List<DupFiles.Item> all = new ArrayList<DupFiles.Item>();
        all.add(new DupFiles.Item("a", "x/a.mp3", "a.mp3", 100));
        all.add(new DupFiles.Item("b", "y/b.mp3", "b.mp3", 100));
        all.add(new DupFiles.Item("c", "z/c.mp3", "c.mp3", 200));
        all.add(new DupFiles.Item("d", "z/d.mp3", "d.mp3", 0));
        List<List<DupFiles.Item>> buckets = DupFiles.bySize(all);
        check("只有一组同大小", buckets.size() == 1);
        check("组里两个文件", buckets.get(0).size() == 2);
    }

    /** 2. 同大小但哈希不同 → 不算重复。 */
    static void groupsNeedSameHash() {
        List<DupFiles.Item> c = new ArrayList<DupFiles.Item>();
        DupFiles.Item a = new DupFiles.Item("a", "x/a.mp3", "a.mp3", 100);
        a.hash = "h1";
        DupFiles.Item b = new DupFiles.Item("b", "y/b.mp3", "b.mp3", 100);
        b.hash = "h2";
        DupFiles.Item d = new DupFiles.Item("d", "z/d.mp3", "d.mp3", 100);
        d.hash = "h1";
        c.add(a);
        c.add(b);
        c.add(d);
        List<DupFiles.Group> groups = DupFiles.groups(c);
        check("只有 h1 成组", groups.size() == 1);
        check("h1 组里两个", groups.get(0).items.size() == 2);
        check("空哈希被忽略", DupFiles.groups(new ArrayList<DupFiles.Item>()).isEmpty());
    }

    /** 3. 建议保留目录层级最浅的那份。 */
    static void suggestKeepShallowest() {
        DupFiles.Item deep = new DupFiles.Item("a", "歌手/专辑/歌.mp3", "歌.mp3", 10);
        DupFiles.Item shallow = new DupFiles.Item("b", "歌.mp3", "歌.mp3", 10);
        DupFiles.Item mid = new DupFiles.Item("c", "歌手/歌.mp3", "歌.mp3", 10);
        List<DupFiles.Item> c = new ArrayList<DupFiles.Item>();
        for (DupFiles.Item it : new DupFiles.Item[]{deep, shallow, mid}) {
            it.hash = "same";
            c.add(it);
        }
        List<DupFiles.Group> groups = DupFiles.groups(c);
        check("三个成一组", groups.size() == 1 && groups.get(0).items.size() == 3);
        check("保留最浅的那份", groups.get(0).suggestKeep() == shallow);

        // 层级相同时按路径长度，再按字典序
        DupFiles.Item longName = new DupFiles.Item("d", "a/b/长长的名字.mp3", "长长的名字.mp3", 10);
        longName.hash = "same2";
        DupFiles.Item shortName = new DupFiles.Item("e", "a/b/s.mp3", "s.mp3", 10);
        shortName.hash = "same2";
        List<DupFiles.Item> c2 = new ArrayList<DupFiles.Item>();
        c2.add(longName);
        c2.add(shortName);
        check("同层级取路径短的", DupFiles.groups(c2).get(0).suggestKeep() == shortName);
    }

    /** 4. 浪费空间 = 大小 ×（份数−1），组按浪费量倒序。 */
    static void wastedAndOrder() {
        List<DupFiles.Item> small = new ArrayList<DupFiles.Item>();
        for (int i = 0; i < 2; i++) {
            DupFiles.Item it = new DupFiles.Item("s" + i, "s" + i + ".mp3", "s.mp3", 100);
            it.hash = "hs";
            small.add(it);
        }
        List<DupFiles.Item> big = new ArrayList<DupFiles.Item>();
        for (int i = 0; i < 3; i++) {
            DupFiles.Item it = new DupFiles.Item("b" + i, "b" + i + ".mp3", "b.mp3", 1000);
            it.hash = "hb";
            big.add(it);
        }
        List<DupFiles.Item> all = new ArrayList<DupFiles.Item>();
        all.addAll(small);
        all.addAll(big);
        List<DupFiles.Group> groups = DupFiles.groups(all);
        check("两组", groups.size() == 2);
        check("小浪费 100", groups.get(1).wasted() == 100);
        check("大浪费 2000", groups.get(0).wasted() == 2000);
        check("浪费大的排前面", groups.get(0).wasted() > groups.get(1).wasted());
    }

    /** 5. 汇总文案包含组数与副本数。 */
    static void summaryText() {
        List<DupFiles.Item> c = new ArrayList<DupFiles.Item>();
        for (int i = 0; i < 3; i++) {
            DupFiles.Item it = new DupFiles.Item("x" + i, "x" + i + ".mp3", "x.mp3", 1024 * 1024);
            it.hash = "h";
            c.add(it);
        }
        String s = DupFiles.summary(DupFiles.groups(c));
        check("提到 1 组", s.contains("1 组"));
        check("提到 2 个副本", s.contains("2 个多余副本"));
        check("空结果有说明", DupFiles.summary(new ArrayList<DupFiles.Group>()).contains("没有发现"));
    }

    /** 6. 哈希对相同前缀稳定、对不同内容不同。 */
    static void hashOfBytes() {
        byte[] a = new byte[]{1, 2, 3, 4};
        byte[] b = new byte[]{1, 2, 3, 4};
        byte[] c = new byte[]{1, 2, 3, 5};
        check("同内容同哈希", DupFiles.hash(a).equals(DupFiles.hash(b)));
        check("不同内容不同哈希", !DupFiles.hash(a).equals(DupFiles.hash(c)));
        check("空数据返回空串", DupFiles.hash(new byte[0]).isEmpty());
        check("哈希是 64 位十六进制", DupFiles.hash(a).length() == 64);
    }

    /** 2b. 采样指纹：头相同但尾不同必须区分开（v0.1.88 的核心修复）。 */
    static void sampleHashTailMatters() {
        byte[] head = new byte[]{1, 2, 3, 4};
        byte[] tailSame = new byte[]{9, 9};
        byte[] tailOther = new byte[]{9, 8};
        String base = DupFiles.sampleHash(head, tailSame, 1000);
        check("头尾都同 → 指纹相同",
                base.equals(DupFiles.sampleHash(head, tailSame, 1000)));
        check("头同尾不同 → 指纹不同",
                !base.equals(DupFiles.sampleHash(head, tailOther, 1000)));
        check("头尾同但大小不同 → 指纹不同",
                !base.equals(DupFiles.sampleHash(head, tailSame, 1001)));
        check("尾部读不到（null）也能出指纹", !DupFiles.sampleHash(head, null, 1000).isEmpty());
        check("头部为空返回空串", DupFiles.sampleHash(new byte[0], tailSame, 10).isEmpty());
    }

    private static void check(String label, boolean ok) {
        if (ok) {
            passed++;
        } else {
            failed++;
            System.out.println("[FAIL] " + label);
        }
    }
}
