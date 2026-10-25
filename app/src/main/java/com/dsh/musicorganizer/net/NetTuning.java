package com.dsh.musicorganizer.net;

/**
 * 网络并发度与超时的可调参数（纯 Java，可离线测试）。
 *
 * <p>为什么现在要把它做成可调：原来 {@code Net.FILE_CONCURRENCY} 是 {@code static final 3}、
 * 连接超时写死 3.5 秒、单源预算写死 12 秒 —— 这套数值按「手机 + 家用宽带」定的，
 * 到了两种真实场景都不合适：
 * <ul>
 *   <li><b>弱网 / 地铁 / 老小区</b>：3 路并发会互相抢带宽，全部卡在超时上，
 *       反而不如 1~2 路稳稳跑；超时也需要放宽，否则每次都在「快下完」时被掐断。</li>
 *   <li><b>低端机 / 老安卓</b>：3 路同时解析证书 + 解压响应，CPU 先成瓶颈。</li>
 *   <li><b>好网 + 海外源</b>：适当提到 4~5 路能明显缩短整批时间。</li>
 * </ul>
 *
 * <p>超时用一个<b>百分比倍率</b>而不是逐个源暴露秒数：源有四家到八家，每家的合理超时
 * （LRCLIB 短、MusicBrainz 长）都是按接口特性调的，让用户逐项改既难懂又容易改坏。
 * 倍率只做整体缩放，相对关系保持不变。
 *
 * <p>线程池不在这里重建：文件级并发每批现建现销毁（见 {@code Net.mapIndexed}），
 * 所以改并发度对下一批立即生效，不需要动共享池。
 */
public final class NetTuning {

    /** 同时处理的文件数：默认 3（手机 + 家用网络的最优区间）。 */
    public static final int DEFAULT_FILE_CONCURRENCY = 3;
    public static final int MIN_FILE_CONCURRENCY = 1;
    public static final int MAX_FILE_CONCURRENCY = 5;

    /** 超时倍率（百分比）：默认 100 即原值。 */
    public static final int DEFAULT_TIMEOUT_PERCENT = 100;
    public static final int MIN_TIMEOUT_PERCENT = 50;
    public static final int MAX_TIMEOUT_PERCENT = 300;

    /** 界面上给的档位：0.5× / 1× / 1.5× / 2× / 3×。 */
    public static final int[] TIMEOUT_STEPS = {50, 100, 150, 200, 300};

    private static volatile int fileConcurrency = DEFAULT_FILE_CONCURRENCY;
    private static volatile int timeoutPercent = DEFAULT_TIMEOUT_PERCENT;

    private NetTuning() {
    }

    /**
     * 应用一组设置；越界自动收缩到合法区间（导入别人的备份、手改偏好都可能越界）。
     *
     * @return 实际生效的并发度
     */
    public static int apply(int concurrency, int percent) {
        int c = clamp(concurrency, MIN_FILE_CONCURRENCY, MAX_FILE_CONCURRENCY);
        int p = clamp(percent, MIN_TIMEOUT_PERCENT, MAX_TIMEOUT_PERCENT);
        fileConcurrency = c;
        timeoutPercent = p;
        return c;
    }

    public static int fileConcurrency() {
        return fileConcurrency;
    }

    public static int timeoutPercent() {
        return timeoutPercent;
    }

    /**
     * 按倍率缩放一个超时值（毫秒）。
     *
     * <p>下限 300ms：倍率 0.5× 时 400ms 的连接超时会变成 200ms，在移动网络下几乎必然失败，
     * 与其给出一个「一定超时」的配置，不如留一条底线。
     */
    public static int scale(int ms) {
        int v = (int) Math.round(ms * (timeoutPercent / 100.0));
        return Math.max(300, v);
    }

    public static long scale(long ms) {
        return Math.max(300L, Math.round(ms * (timeoutPercent / 100.0)));
    }

    /** 界面上的档位文案，如「1.5×」。 */
    public static String timeoutLabel(int percent) {
        if (percent % 100 == 0) {
            return (percent / 100) + "×";
        }
        return String.format(java.util.Locale.US, "%.1f×", percent / 100.0);
    }

    /** 一句话说明当前档位（设置页副标题、日志里用）。 */
    public static String describe() {
        String hint;
        if (fileConcurrency <= 1) {
            hint = "逐首处理";
        } else if (fileConcurrency >= 4) {
            hint = "较激进";
        } else {
            hint = "推荐";
        }
        return fileConcurrency + " 首并发（" + hint + "）· 超时 " + timeoutLabel(timeoutPercent);
    }

    private static int clamp(int v, int min, int max) {
        return Math.max(min, Math.min(v, max));
    }
}
