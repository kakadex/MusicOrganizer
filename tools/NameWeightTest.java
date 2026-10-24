import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.core.TaskControl;

/**
 * 离线回归测试（纯 JVM）：文件名权重决策 + 任务暂停/取消语义。
 * 不依赖 Android，可用 tools/run_core_test.sh 直接跑。
 */
public class NameWeightTest {

    static int fails = 0;

    static void eq(String name, String expect, String actual) {
        boolean ok = expect.equals(actual);
        if (!ok) {
            fails++;
        }
        System.out.println((ok ? "  ok   " : "  FAIL ") + name
                + (ok ? "" : "  期望=[" + expect + "] 实际=[" + actual + "]"));
    }

    static void ok(String name, boolean cond) {
        if (!cond) {
            fails++;
        }
        System.out.println((cond ? "  ok   " : "  FAIL ") + name);
    }

    public static void main(String[] a) throws Exception {
        System.out.println("[1] 权重 0% —— 只信已有标签");
        eq("pick(文件名, 标签)", "标签歌名",
                NameWeight.pick("文件歌名", "标签歌名", 0.0));
        eq("标签为空时回退文件名", "文件歌名",
                NameWeight.pick("文件歌名", "", 0.0));

        System.out.println("[2] 权重 100% —— 只信文件名");
        eq("pick(文件名, 标签)", "文件歌名",
                NameWeight.pick("文件歌名", "标签歌名", 1.0));
        eq("文件名为空时回退标签", "标签歌名",
                NameWeight.pick("", "标签歌名", 1.0));

        System.out.println("[3] 50% 分界线（>=50 以文件名为准）");
        eq("49% 取标签", "标签歌名", NameWeight.pick("文件歌名", "标签歌名", 0.49));
        eq("50% 取文件名", "文件歌名", NameWeight.pick("文件歌名", "标签歌名", 0.5));

        System.out.println("[4] 备选值");
        eq("20% 的备选是文件名", "文件歌名",
                NameWeight.pickSecondary("文件歌名", "标签歌名", 0.2));
        eq("80% 的备选是标签", "标签歌名",
                NameWeight.pickSecondary("文件歌名", "标签歌名", 0.8));
        eq("两边一致时无备选", "",
                NameWeight.pickSecondary("同名", "同名", 0.2));

        System.out.println("[5] 百分比换算与越界收缩");
        ok("fromPercent(30)=0.30", Math.abs(NameWeight.fromPercent(30) - 0.30) < 1e-9);
        ok("fromPercent(-5) 收敛到 0", NameWeight.fromPercent(-5) == 0.0);
        ok("fromPercent(180) 收敛到 1", NameWeight.fromPercent(180) == 1.0);
        ok("clamp(NaN) 走默认值", Math.abs(NameWeight.clamp(Double.NaN)
                - NameWeight.fromPercent(NameWeight.DEFAULT_PERCENT)) < 1e-9);

        System.out.println("[6] TaskControl：进度上报");
        TaskControl c = new TaskControl("准备中");
        c.report(3, 12, "正在匹配：a.mp3");
        eq("percent", "25", String.valueOf(c.percent()));
        c.report(0, 0, "扫描中");
        eq("总量未知 -> -1", "-1", String.valueOf(c.percent()));
        ok("summary 含当前文件", c.summary().contains("扫描中"));

        System.out.println("[7] TaskControl：取消后检查点立即返回 true");
        TaskControl c2 = new TaskControl();
        ok("未取消时 false", !c2.isCancelled());
        c2.cancel();
        ok("取消后 true", c2.isCancelled());
        ok("isCancelledNow 同步为 true", c2.isCancelledNow());

        System.out.println("[8] TaskControl：暂停会让工作线程停在检查点，恢复后继续");
        final TaskControl c3 = new TaskControl();
        final long[] passedAt = new long[1];
        Thread worker = new Thread(new Runnable() {
            @Override
            public void run() {
                c3.isCancelled();          // 第一个检查点（未暂停，直接过）
                c3.pause();
                c3.isCancelled();          // 这里应当阻塞
                passedAt[0] = System.currentTimeMillis();
            }
        });
        long start = System.currentTimeMillis();
        worker.start();
        Thread.sleep(400);
        ok("暂停期间工作线程被阻塞", worker.isAlive() && passedAt[0] == 0);
        ok("已过 400ms 仍未继续", System.currentTimeMillis() - start >= 400);
        c3.resume();
        worker.join(2000);
        ok("恢复后工作线程继续并结束", !worker.isAlive() && passedAt[0] > 0);

        System.out.println("[9] TaskControl：暂停中取消可直接退出");
        final TaskControl c4 = new TaskControl();
        final boolean[] returned = new boolean[1];
        Thread w2 = new Thread(new Runnable() {
            @Override
            public void run() {
                c4.pause();
                returned[0] = c4.isCancelled();   // 暂停中阻塞，取消后应返回 true
            }
        });
        w2.start();
        Thread.sleep(300);
        c4.cancel();
        w2.join(2000);
        ok("暂停中取消能唤醒并返回 true", returned[0]);

        System.out.println(fails == 0 ? "\n全部通过 ✅" : "\n失败 " + fails + " 项 ❌");
        if (fails != 0) {
            System.exit(1);
        }
    }
}
