import com.dsh.musicorganizer.core.CoverArt;

/**
 * 封面字节解析回归测试（纯 JVM）。
 *
 * 覆盖：JPEG/PNG 识别、尺寸解析、非法数据容错、可读大小。
 */
public final class CoverArtTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        sniffing();
        sizes();
        robustness();
        text();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    private static void sniffing() {
        section("格式识别");
        check("JPEG", CoverArt.isJpeg(jpeg(100, 50)));
        check("PNG", CoverArt.isPng(png(100, 50)));
        check("JPEG MIME", "image/jpeg".equals(CoverArt.mimeOf(jpeg(10, 10))));
        check("PNG MIME", "image/png".equals(CoverArt.mimeOf(png(10, 10))));
        check("随便的字节不认", CoverArt.mimeOf(new byte[]{1, 2, 3, 4}).isEmpty());
        check("空数组不认", CoverArt.mimeOf(new byte[0]).isEmpty());
        check("null 不认", CoverArt.mimeOf(null).isEmpty());
    }

    private static void sizes() {
        section("尺寸解析");
        check("JPEG 100×50", dims(jpeg(100, 50), 100, 50));
        check("JPEG 1920×1080", dims(jpeg(1920, 1080), 1920, 1080));
        check("PNG 800×800", dims(png(800, 800), 800, 800));
        check("未知格式返回 0", dims(new byte[]{9, 9, 9, 9}, 0, 0));
    }

    private static void robustness() {
        section("容错");
        check("截断的 JPEG 不崩", CoverArt.dimensions(new byte[]{(byte) 0xFF, (byte) 0xD8})[0] == 0);
        check("只有 PNG 头不崩", dims(png(1, 1), 1, 1));
        check("描述里有格式", CoverArt.describe(jpeg(120, 90)).startsWith("JPEG"));
        check("描述里有尺寸", CoverArt.describe(jpeg(120, 90)).contains("120×90"));
        check("空图片描述", CoverArt.describe(new byte[0]).contains("无图片"));
    }

    private static void text() {
        section("大小文案与上限");
        check("B", "512 B".equals(CoverArt.sizeText(512)));
        check("KB", CoverArt.sizeText(4096).endsWith(" KB"));
        check("MB", CoverArt.sizeText(2L * 1024 * 1024).endsWith(" MB"));
        check("上限是 4MB", CoverArt.MAX_BYTES == 4 * 1024 * 1024);
    }

    // ------------------------------------------------------------------

    private static boolean dims(byte[] img, int w, int h) {
        int[] d = CoverArt.dimensions(img);
        return d[0] == w && d[1] == h;
    }

    private static byte[] jpeg(int w, int h) {
        return new byte[]{
                (byte) 0xFF, (byte) 0xD8,
                (byte) 0xFF, (byte) 0xC0, 0x00, 0x11, 0x08,
                (byte) ((h >> 8) & 0xFF), (byte) (h & 0xFF),
                (byte) ((w >> 8) & 0xFF), (byte) (w & 0xFF),
                0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
                (byte) 0xFF, (byte) 0xD9,
        };
    }

    private static byte[] png(int w, int h) {
        return new byte[]{(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A,
                0, 0, 0, 13, 'I', 'H', 'D', 'R',
                (byte) (w >> 24), (byte) (w >> 16), (byte) (w >> 8), (byte) w,
                (byte) (h >> 24), (byte) (h >> 16), (byte) (h >> 8), (byte) h,
                8, 6, 0, 0, 0};
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
