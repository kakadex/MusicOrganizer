import com.dsh.musicorganizer.core.SettingsBackup;
import com.dsh.musicorganizer.net.Net;
import com.dsh.musicorganizer.net.NetTuning;

/**
 * 网络并发 / 超时可调参数回归测试（纯 JVM）。
 *
 * 覆盖：
 *   1. 并发度的取值区间与越界收缩
 *   2. 超时倍率的取值区间与越界收缩
 *   3. 缩放：默认 100% 不改变原值、放大缩小正确、下限 300ms
 *   4. 单源预算随倍率同步缩放（否则「调大超时」会被预算提前截断，表现为设置不生效）
 *   5. 与设置备份的接线：默认值一致、键被识别为整数、导入越界值被修正
 *   6. 档位文案
 */
public final class NetTuningTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        bounds();
        scaling();
        budget();
        backupWiring();
        labels();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void bounds() {
        section("取值区间");
        NetTuning.apply(3, 100);
        check("默认并发 3", NetTuning.fileConcurrency() == 3);
        check("默认倍率 100", NetTuning.timeoutPercent() == 100);

        NetTuning.apply(0, 100);
        check("并发 0 收到 1", NetTuning.fileConcurrency() == 1);
        NetTuning.apply(99, 100);
        check("并发 99 收到 5", NetTuning.fileConcurrency() == 5);
        NetTuning.apply(-7, 100);
        check("并发负数收到 1", NetTuning.fileConcurrency() == 1);

        NetTuning.apply(3, 0);
        check("倍率 0 收到 50", NetTuning.timeoutPercent() == 50);
        NetTuning.apply(3, 9999);
        check("倍率 9999 收到 300", NetTuning.timeoutPercent() == 300);

        NetTuning.apply(3, 100);
        check("复位后并发 3", NetTuning.fileConcurrency() == 3);
        check("复位后倍率 100", NetTuning.timeoutPercent() == 100);
    }

    private static void scaling() {
        section("超时缩放");
        NetTuning.apply(3, 100);
        check("100% 不改原值", NetTuning.scale(12000) == 12000);
        check("int 版本一致", NetTuning.scale(3500) == 3500);

        NetTuning.apply(3, 200);
        check("200% 翻倍", NetTuning.scale(12000) == 24000);
        NetTuning.apply(3, 50);
        check("50% 减半", NetTuning.scale(12000) == 6000);
        check("下限兜底 300ms", NetTuning.scale(200) == 300);
        NetTuning.apply(3, 300);
        check("300% 三倍", NetTuning.scale(1000) == 3000);
        check("long 版本一致", NetTuning.scale((long) 9000) == 27000L);
        NetTuning.apply(3, 100);
    }

    private static void budget() {
        section("单源预算联动");
        NetTuning.apply(3, 100);
        check("默认预算 = 常量", Net.sourceBudgetMs() == Net.SOURCE_BUDGET_MS);
        NetTuning.apply(3, 200);
        check("倍率 2x 预算同步放大",
                Net.sourceBudgetMs() == Math.round(Net.SOURCE_BUDGET_MS * 2.0));
        NetTuning.apply(3, 50);
        check("倍率 0.5x 预算同步缩小",
                Net.sourceBudgetMs() == Math.round(Net.SOURCE_BUDGET_MS * 0.5));
        check("文件并发读数一致", Net.fileConcurrency() == NetTuning.fileConcurrency());
        NetTuning.apply(3, 100);
    }

    private static void backupWiring() {
        section("设置备份接线");
        Object defFiles = SettingsBackup.defaults().get(SettingsBackup.KEY_NET_FILES);
        Object defTime = SettingsBackup.defaults().get(SettingsBackup.KEY_NET_TIMEOUT);
        check("默认值与 NetTuning 一致",
                defFiles instanceof Integer && ((Integer) defFiles) == NetTuning.DEFAULT_FILE_CONCURRENCY);
        check("超时默认值一致",
                defTime instanceof Integer && ((Integer) defTime) == NetTuning.DEFAULT_TIMEOUT_PERCENT);
        check("并发键可备份",
                SettingsBackup.isKnownKey(SettingsBackup.KEY_NET_FILES));
        check("超时键可备份",
                SettingsBackup.isKnownKey(SettingsBackup.KEY_NET_TIMEOUT));

        java.util.List<String> warns = new java.util.ArrayList<String>();
        Object clamped = SettingsBackup.sanitize(SettingsBackup.KEY_NET_FILES, Integer.valueOf(9), warns);
        check("导入越界并发被收到 5", clamped instanceof Integer && ((Integer) clamped) == 5);
        check("越界有告警", !warns.isEmpty());

        warns.clear();
        Object clamped2 = SettingsBackup.sanitize(SettingsBackup.KEY_NET_TIMEOUT, Integer.valueOf(10), warns);
        check("导入过小倍率被收到 50",
                clamped2 instanceof Integer && ((Integer) clamped2) == 50);

        warns.clear();
        Object ok = SettingsBackup.sanitize(SettingsBackup.KEY_NET_TIMEOUT, Integer.valueOf(150), warns);
        check("合法值不改动", ok instanceof Integer && ((Integer) ok) == 150);
    }

    private static void labels() {
        section("文案");
        check("整倍率文案", "2×".equals(NetTuning.timeoutLabel(200)));
        check("半档文案", "1.5×".equals(NetTuning.timeoutLabel(150)));
        NetTuning.apply(1, 100);
        check("1 路标逐首", NetTuning.describe().contains("逐首"));
        NetTuning.apply(5, 200);
        check("5 路标激进", NetTuning.describe().contains("激进"));
        check("描述含倍率", NetTuning.describe().contains("2×"));
        NetTuning.apply(3, 100);
        check("默认标推荐", NetTuning.describe().contains("推荐"));
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
