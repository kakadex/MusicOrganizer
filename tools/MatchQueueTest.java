import com.dsh.musicorganizer.core.MatchQueue;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 批量匹配中间态（断点续跑）回归测试（纯 JVM）。
 *
 * 覆盖：
 *   1. 记录 / 取回 / 指纹（size + mtime）变化后失效
 *   2. 状态流转：pending → written / skipped / failed，已收尾的不再被取回
 *   3. 落盘与重新加载（模拟进程被杀后重启）
 *   4. clearFinished 只留 pending
 *   5. 过期条目、空字段、损坏 JSON 的容错
 *   6. 摘要文案与待写入键列表
 */
public final class MatchQueueTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) throws Exception {
        File dir = new File(System.getProperty("java.io.tmpdir"),
                "matchqueue-test-" + System.nanoTime());
        dir.mkdirs();

        basics(dir);
        statuses(dir);
        persist(dir);
        clearFinished(dir);
        robustness(dir);
        expire(dir);
        cleanup(dir);

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void basics(File dir) {
        section("记录与取回");
        MatchQueue q = MatchQueue.open(dir, "t1");
        check("初始没有待写入", q.countPending() == 0);
        check("取不存在的键返回 null", q.take("a.mp3", 100, 1000) == null);

        Map<String, String> f = new HashMap<String, String>();
        f.put("title", "示例标题");
        f.put("artist", "示例歌手");
        f.put("@src", "netease");
        f.put("@conf", "0.92");
        q.put("a.mp3", 100, 1000, f);

        check("待写入计数 1", q.countPending() == 1);
        MatchQueue.Item it = q.take("a.mp3", 100, 1000);
        check("能取回", it != null);
        check("字段完整", it != null && "示例标题".equals(it.fields.get("title")));
        check("元信息完整", it != null && "0.92".equals(it.field("@conf", "")));
        check("状态是 pending", it != null && it.isPending());

        // 取回的是副本：改它不影响队列
        if (it != null) {
            it.fields.put("title", "被改掉");
        }
        MatchQueue.Item again = q.take("a.mp3", 100, 1000);
        check("取回的是副本", again != null && "示例标题".equals(again.fields.get("title")));
    }

    private static void statuses(File dir) {
        section("指纹与状态");
        MatchQueue q = MatchQueue.open(dir, "t2");
        Map<String, String> f = new HashMap<String, String>();
        f.put("title", "标题");
        q.put("b.mp3", 200, 2000, f);

        check("大小变了就不给", q.take("b.mp3", 201, 2000) == null);
        check("失效条目被剔除", q.countPending() == 0);

        q.put("c.mp3", 300, 3000, f);
        check("时间变了就不给", q.take("c.mp3", 300, 3001) == null);

        q.put("d.mp3", 400, 4000, f);
        q.mark("d.mp3", MatchQueue.WRITTEN);
        check("已写入不再取回", q.take("d.mp3", 400, 4000) == null);
        check("已写入不算待写入", q.countPending() == 0);
        check("状态计数正确", q.countOf(MatchQueue.WRITTEN) == 1);

        q.put("e.mp3", 500, 5000, f);
        q.mark("e.mp3", MatchQueue.SKIPPED);
        check("跳过也不取回", q.take("e.mp3", 500, 5000) == null);

        q.put("g.mp3", 700, 7000, f);
        q.mark("g.mp3", MatchQueue.FAILED);
        check("失败也不取回", q.take("g.mp3", 700, 7000) == null);

        // mtime 为 0（个别 SAF provider 取不到）时只比大小
        q.put("h.mp3", 800, 0, f);
        check("mtime 缺失时按大小命中", q.take("h.mp3", 800, 1234) != null);
    }

    private static void persist(File dir) {
        section("落盘与重新加载");
        MatchQueue q = MatchQueue.open(dir, "t3");
        Map<String, String> f = new HashMap<String, String>();
        f.put("@content", "第一行\n第二行");
        q.put("x.mp3", 10, 20, f);
        q.save();

        MatchQueue reload = MatchQueue.open(dir, "t3");
        check("重启后仍在", reload.countPending() == 1);
        MatchQueue.Item it = reload.take("x.mp3", 10, 20);
        check("正文原样还原", it != null && "第一行\n第二行".equals(it.field("@content", "")));

        MatchQueue other = MatchQueue.open(dir, "other");
        check("不同 kind 互不干扰", other.countPending() == 0);
        check("文件名带 queue- 前缀",
                reload.file() != null && reload.file().getName().startsWith("queue-"));
    }

    private static void clearFinished(File dir) {
        section("收尾清理");
        MatchQueue q = MatchQueue.open(dir, "t4");
        Map<String, String> f = new HashMap<String, String>();
        f.put("title", "t");
        q.put("p1", 1, 1, f);
        q.put("p2", 1, 1, f);
        q.put("p3", 1, 1, f);
        q.mark("p1", MatchQueue.WRITTEN);
        q.mark("p2", MatchQueue.SKIPPED);
        q.clearFinished();

        check("只剩待写入的", q.countPending() == 1);
        List<String> keys = q.pendingKeys();
        check("待写入键正确", keys.size() == 1 && "p3".equals(keys.get(0)));
        check("摘要提到续跑", q.summary().contains("待写入"));
    }

    private static void robustness(File dir) throws Exception {
        section("容错");
        File bad = new File(dir, "queue-bad.json");
        Writer w = new OutputStreamWriter(new FileOutputStream(bad), "UTF-8");
        w.write("{ this is not json ");
        w.close();
        MatchQueue q = MatchQueue.open(dir, "bad");
        check("损坏文件不崩", q.countPending() == 0);

        MatchQueue q2 = MatchQueue.open(dir, "empty");
        Map<String, String> f = new HashMap<String, String>();
        f.put("title", "t");
        q2.put("", 1, 1, f);
        check("空键被忽略", q2.countPending() == 0);
        check("空摘要文案", MatchQueue.open(dir, "none").summary().contains("无待写入"));
    }

    /** 手写一份 20 天前的中间态：加载时应作废，不再让用户「续跑」过期结果。 */
    private static void expire(File dir) throws Exception {
        section("过期作废");
        File f = new File(dir, "queue-old.json");
        long old = System.currentTimeMillis() - 20L * 24 * 3600 * 1000;
        String json = "{\"version\":1,\"kind\":\"old\",\"items\":[{\"k\":\"z.mp3\","
                + "\"s\":1,\"m\":1,\"st\":\"pending\",\"t\":" + old
                + ",\"f\":{\"title\":\"旧结果\"}}]}";
        Writer w = new OutputStreamWriter(new FileOutputStream(f), "UTF-8");
        w.write(json);
        w.close();

        MatchQueue q = MatchQueue.open(dir, "old");
        check("过期条目不参与续跑", q.take("z.mp3", 1, 1) == null);
        check("过期条目已丢弃", q.countPending() == 0);
    }

    private static void cleanup(File dir) {
        section("清理");
        File[] files = dir.listFiles();
        int n = 0;
        if (files != null) {
            for (File f : files) {
                if (f.delete()) {
                    n++;
                }
            }
        }
        check("临时文件已清理", n >= 1 && dir.delete());
    }

    private static void section(String title) {
        System.out.println("[ " + title + " ]");
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("  ok   " + name);
        } else {
            failed++;
            System.out.println("  FAIL " + name);
        }
    }
}
