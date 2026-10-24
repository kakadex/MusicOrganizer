import com.dsh.musicorganizer.core.MoveLog;

import java.util.ArrayList;
import java.util.List;

/**
 * 整理移动日志的格式与分组回归（纯 JVM）。
 *
 * <p>盯的是「日志能读回来、批次能对上」：TSV 序列化往返、字段里的制表符与换行不会把一行拆成两行、
 * 坏行不能污染整份日志、撤销顺序必须逆序。
 */
public class MoveLogTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        MoveLog.Record r = new MoveLog.Record("b1", "2026-10-23 04:00:00",
                "primary:Music", "晴天.mp3", "primary:Music/周杰伦", "晴天.mp3");

        // 1) 序列化 / 解析往返
        String line = MoveLog.serialize(r);
        check("六个字段", line.split("\t", -1).length == 6);
        MoveLog.Record back = MoveLog.parse(line);
        check("往返批次", back != null && back.batchId.equals("b1"));
        check("往返原目录", back != null && back.fromDir.equals("primary:Music"));
        check("往返目标目录", back != null && back.toDir.equals("primary:Music/周杰伦"));
        check("往返文件名", back != null && back.toName.equals("晴天.mp3"));

        // 2) 字段里的制表符/换行被清掉（否则一行变多行）
        MoveLog.Record dirty = new MoveLog.Record("b2", "t", "a", "坏\n名\t字.mp3", "d", "x.mp3");
        String dirtyLine = MoveLog.serialize(dirty);
        check("制表符被替换", dirtyLine.indexOf('\n') < 0);
        check("字段数仍是 6", dirtyLine.split("\t", -1).length == 6);
        MoveLog.Record dirtyBack = MoveLog.parse(dirtyLine);
        check("脏字段能读回", dirtyBack != null
                && dirtyBack.fromName.equals("坏 名 字.mp3"));

        // 3) 坏行
        check("字段不足返回 null", MoveLog.parse("a\tb") == null);
        check("null 返回 null", MoveLog.parse(null) == null);
        check("空批次号跳过", MoveLog.parse("\tt\t\t\t\t") == null);
        check("空目标目录跳过", MoveLog.parse("b\tt\ta\tn\t\tx") == null);

        // 4) 批次折叠
        List<MoveLog.Record> records = new ArrayList<MoveLog.Record>();
        records.add(new MoveLog.Record("b1", "2026-10-23 01:00:00", "d", "a.mp3", "t", "a.mp3"));
        records.add(new MoveLog.Record("b1", "2026-10-23 01:00:05", "d", "b.mp3", "t", "b.mp3"));
        records.add(new MoveLog.Record("b2", "2026-10-23 02:00:00", "d", "c.mp3", "t", "c.mp3"));
        List<MoveLog.Batch> batches = MoveLog.group(records);
        check("两个批次", batches.size() == 2);
        check("最新批次在前", batches.get(0).batchId.equals("b2"));
        check("第一批 2 个", batches.get(1).count == 2);
        check("批次时间取最后一条", batches.get(1).time.equals("2026-10-23 01:00:05"));
        check("标题带个数", batches.get(1).title().endsWith("2 个文件"));

        // 5) 逆序
        List<MoveLog.Record> rev = MoveLog.reversed(records);
        check("逆序首位", rev.get(0).toName.equals("c.mp3"));
        check("逆序末位", rev.get(2).toName.equals("a.mp3"));
        check("逆序长度不变", rev.size() == records.size());
        check("null 逆序安全", MoveLog.reversed(null).isEmpty());

        // 6) 空输入
        check("空表无批次", MoveLog.group(new ArrayList<MoveLog.Record>()).isEmpty());
        check("null 无批次", MoveLog.group(null).isEmpty());
        check("null 序列化为空", MoveLog.serialize(null).isEmpty());

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    private static void check(String label, boolean ok) {
        if (ok) {
            pass++;
            System.out.println("  ok   " + label);
        } else {
            fail++;
            System.out.println("  FAIL " + label);
        }
    }
}
