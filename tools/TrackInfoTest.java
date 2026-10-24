import com.dsh.musicorganizer.core.TrackInfo;

/**
 * 曲目技术信息格式化回归（纯 JVM，v0.1.51）。
 *
 * <p>盯两件事：取不到值时**必须返回空串**（不能印 "0:00" / "0kbps" 让人以为是真实值），
 * 以及四舍五入与跨小时进位（119:59 这种写法播放器不认）。
 */
public class TrackInfoTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 未知值 → 空串
        check("0 毫秒为空", TrackInfo.duration(0).isEmpty());
        check("负毫秒为空", TrackInfo.duration(-1).isEmpty());
        check("0 kbps 为空", TrackInfo.bitrate(0).isEmpty());
        check("负 kbps 为空", TrackInfo.bitrate(-1).isEmpty());

        // 2) 常规时长
        check("1 秒", "0:01".equals(TrackInfo.duration(1000)));
        check("9 秒", "0:09".equals(TrackInfo.duration(9000)));
        check("10 秒", "0:10".equals(TrackInfo.duration(10000)));
        check("59 秒", "0:59".equals(TrackInfo.duration(59000)));
        check("1 分整", "1:00".equals(TrackInfo.duration(60000)));
        check("1 分 1 秒", "1:01".equals(TrackInfo.duration(61000)));
        check("59 分 59 秒", "59:59".equals(TrackInfo.duration(3599000)));

        // 3) 四舍五入到秒：5999ms 显示 0:06，不是 0:05
        check("5999ms 进位到 6 秒", "0:06".equals(TrackInfo.duration(5999)));
        check("59999ms 进位到 1:00", "1:00".equals(TrackInfo.duration(59999)));
        check("500ms 进位到 1 秒", "0:01".equals(TrackInfo.duration(500)));
        check("499ms 仍是 0 秒", "0:00".equals(TrackInfo.duration(499)));

        // 4) 跨小时补小时位（否则 119:59 这种播放器不认）
        check("整 1 小时", "1:00:00".equals(TrackInfo.duration(3600000)));
        check("1 小时 1 秒", "1:00:01".equals(TrackInfo.duration(3601000)));
        check("2 小时 1 分 5 秒", "2:01:05".equals(TrackInfo.duration(7265000)));
        check("10 小时", "10:00:00".equals(TrackInfo.duration(36000000L)));

        // 5) 码率
        check("128kbps", "128kbps".equals(TrackInfo.bitrate(128)));
        check("320kbps", "320kbps".equals(TrackInfo.bitrate(320)));
        check("1000kbps", "1000kbps".equals(TrackInfo.bitrate(1000)));

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
