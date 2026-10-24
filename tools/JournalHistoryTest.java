import com.dsh.musicorganizer.core.JournalHistory;

import java.util.ArrayList;
import java.util.List;

/**
 * 写入历史（批次视图）回归（纯 JVM）。
 *
 * <p>盯的是「撤销」的单位问题：Journal 是逐条流水，用户想撤的是一批。
 * 这里验证折叠、排序、已撤销扣减、单条自成一批、样例名去重、上限截断。
 */
public class JournalHistoryTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 单条写入自成一批；key 用 one: 前缀
        JournalHistory.Row one = row("r1", "2026-10-23 01:00:00", "", "a.mp3", "applied");
        check("单条 key = one:id", JournalHistory.keyOf(one).equals("one:r1"));
        check("批量 key = batchId",
                JournalHistory.keyOf(row("r2", "2026-10-23 01:01:00", "b1", "b.mp3", "applied"))
                        .equals("b1"));

        // 2) 折叠：同 batchId 归一批，条数与样例正确
        List<JournalHistory.Row> rows = new ArrayList<JournalHistory.Row>();
        rows.add(row("1", "2026-10-23 01:00:00", "b1", "晴天.mp3", "applied"));
        rows.add(row("2", "2026-10-23 01:00:02", "b1", "七里香.mp3", "applied"));
        rows.add(row("3", "2026-10-23 01:00:04", "b1", "稻香.mp3", "applied"));
        rows.add(row("4", "2026-10-23 01:00:06", "b1", "夜曲.mp3", "applied"));
        List<JournalHistory.Batch> bs = JournalHistory.build(rows, 0);
        check("一批只出现一次", bs.size() == 1);
        check("条数 4", bs.get(0).count == 4);
        check("批次不是单条", !bs.get(0).single);
        check("样例最多 3 个", bs.get(0).samples.size() == 3);
        check("样例是前三个", bs.get(0).samples.get(0).equals("晴天.mp3")
                && bs.get(0).samples.get(2).equals("稻香.mp3"));
        check("时间取最后一条", bs.get(0).time.equals("2026-10-23 01:00:06"));
        check("标题带条数", bs.get(0).title().endsWith("4 首"));
        check("摘要说明还有更多", bs.get(0).summary().contains("等 4 个文件"));

        // 3) 已撤销的从可撤销条数里扣掉（reverted 记录的 targetId 指向原记录）
        rows.add(revert("9", "2026-10-23 01:01:00", "b1", "1"));
        bs = JournalHistory.build(rows, 0);
        check("扣掉已撤销 1 条", bs.get(0).count == 3);
        check("total 仍是 4", bs.get(0).total == 4);
        check("摘要标已撤销", bs.get(0).summary().contains("1 已撤销"));

        // 4) 全部撤销后该批不再出现
        rows.add(revert("10", "2026-10-23 01:02:00", "b1", "2"));
        rows.add(revert("11", "2026-10-23 01:02:01", "b1", "3"));
        rows.add(revert("12", "2026-10-23 01:02:02", "b1", "4"));
        check("全撤销后列表为空", JournalHistory.build(rows, 0).isEmpty());
        check("targetsOf 也为空", JournalHistory.targetsOf(rows, "b1").isEmpty());

        // 5) 多批按时间倒序
        List<JournalHistory.Row> mixed = new ArrayList<JournalHistory.Row>();
        mixed.add(row("a1", "2026-10-23 00:10:00", "old", "old1.mp3", "applied"));
        mixed.add(row("b1", "2026-10-23 02:30:00", "new", "new1.mp3", "applied"));
        mixed.add(row("c1", "2026-10-22 23:00:00", "", "single.mp3", "applied"));
        List<JournalHistory.Batch> m = JournalHistory.build(mixed, 0);
        check("三批", m.size() == 3);
        check("最新批在前", m.get(0).key.equals("new"));
        check("其次 old", m.get(1).key.equals("old"));
        check("最老在后", m.get(2).key.equals("one:c1"));
        check("单条批标 single", m.get(2).single);

        // 6) 上限截断只留最新的
        check("limit=2 只留两批", JournalHistory.build(mixed, 2).size() == 2);
        check("limit 截断保留最新", JournalHistory.build(mixed, 1).get(0).key.equals("new"));

        // 7) targetsOf 保持写入顺序（撤销时由调用方逆序）
        List<JournalHistory.Row> t = JournalHistory.targetsOf(mixed, "old");
        check("targetsOf 命中 1 条", t.size() == 1 && t.get(0).id.equals("a1"));

        // 8) 样例名去重：同名（不同目录）只算一次
        List<JournalHistory.Row> dup = new ArrayList<JournalHistory.Row>();
        dup.add(row("d1", "2026-10-23 03:00:00", "b9", "同名.mp3", "applied"));
        dup.add(row("d2", "2026-10-23 03:00:01", "b9", "同名.mp3", "applied"));
        JournalHistory.Batch b9 = JournalHistory.build(dup, 0).get(0);
        check("条数 2", b9.count == 2);
        check("样例去重", b9.samples.size() == 1);

        // 9) 旧记录没有 name → 从 uri 推导（含 %xx 解码）
        JournalHistory.Row noName = new JournalHistory.Row();
        noName.id = "e1";
        noName.batchId = "bx";
        noName.timestamp = "2026-10-23 04:00:00";
        noName.uri = "primary:Music/%E6%99%B4%E5%A4%A9.mp3";
        noName.status = "applied";
        List<JournalHistory.Row> nr = new ArrayList<JournalHistory.Row>();
        nr.add(noName);
        check("从 uri 推导文件名",
                JournalHistory.build(nr, 0).get(0).samples.get(0).equals("晴天.mp3"));
        check("uri 去 query",
                JournalHistory.nameFromUri("a/b/x.mp3?foo=1").equals("x.mp3"));

        // 10) 空输入不炸
        check("null 返回空", JournalHistory.build(null, 10).isEmpty());
        check("空表返回空", JournalHistory.build(new ArrayList<JournalHistory.Row>(), 10).isEmpty());
        check("targetsOf null 返回空", JournalHistory.targetsOf(null, "b1").isEmpty());
        check("keyOf null 为空串", JournalHistory.keyOf(null).isEmpty());

        // 11) 只有 reverted 记录（原记录被裁掉）不产生幽灵批次
        List<JournalHistory.Row> ghost = new ArrayList<JournalHistory.Row>();
        ghost.add(revert("g1", "2026-10-23 05:00:00", "bz", "gone"));
        check("幽灵记录不成批", JournalHistory.build(ghost, 0).isEmpty());

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    private static JournalHistory.Row row(String id, String ts, String batch, String name,
                                          String status) {
        JournalHistory.Row r = new JournalHistory.Row();
        r.id = id;
        r.timestamp = ts;
        r.batchId = batch;
        r.name = name;
        r.status = status;
        r.uri = "primary:Music/" + name;
        return r;
    }

    private static JournalHistory.Row revert(String id, String ts, String batch, String target) {
        JournalHistory.Row r = new JournalHistory.Row();
        r.id = id;
        r.timestamp = ts;
        r.batchId = batch;
        r.status = "reverted";
        r.targetId = target;
        return r;
    }

    private static void check(String label, boolean ok) {
        if (ok) {
            pass++;
            System.out.println("  [OK] " + label);
        } else {
            fail++;
            System.out.println("  [FAIL] " + label);
        }
    }
}
