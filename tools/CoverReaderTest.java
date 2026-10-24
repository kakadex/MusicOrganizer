import com.dsh.musicorganizer.core.CoverReader;
import com.dsh.musicorganizer.core.CoverArt;
import com.dsh.musicorganizer.core.Flac;
import com.dsh.musicorganizer.core.Id3;

import java.io.File;
import java.io.FileOutputStream;
import java.util.HashMap;

/**
 * 封面读取回归（纯 JVM）：写入后用独立读取器读回来。
 *
 * 重点不是「写进去了」，而是「读出来的字节与写进去的完全一致」——
 * 写和读是两套独立实现，只有往返才能证明两边对结构和偏移的理解一致。
 */
public final class CoverReaderTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) throws Exception {
        String dir = args.length > 0 ? args[0] : System.getProperty("java.io.tmpdir");
        File work = new File(dir, "coverreader");
        //noinspection ResultOfMethodCallIgnored
        work.mkdirs();

        File mp3 = new File(work, "a.mp3");
        File flac = new File(work, "b.flac");
        writeMp3(mp3);
        writeFlac(flac);

        byte[] jpeg = fakeJpeg(320, 240);
        byte[] png = fakePng(600, 600);

        section("MP3 APIC");
        check("初始没有封面", !CoverReader.has(mp3));
        check("初始读出 null", CoverReader.read(mp3) == null);
        Id3.rewrite(mp3, new HashMap<String, String>(), jpeg);
        check("写入后有", CoverReader.has(mp3));
        check("字节与写入一致", java.util.Arrays.equals(jpeg, CoverReader.read(mp3)));
        Id3.rewrite(mp3, new HashMap<String, String>(), png);
        check("替换后仍是新图", java.util.Arrays.equals(png, CoverReader.read(mp3)));
        Id3.rewrite(mp3, new HashMap<String, String>(), new byte[0]);
        check("删除后没有", !CoverReader.has(mp3));

        section("FLAC PICTURE");
        check("初始没有", !CoverReader.has(flac));
        Flac.rewrite(flac, new HashMap<String, String>(), jpeg);
        check("写入后有", CoverReader.has(flac));
        check("字节与写入一致", java.util.Arrays.equals(jpeg, CoverReader.read(flac)));
        Flac.rewrite(flac, new HashMap<String, String>(), new byte[0]);
        check("删除后没有", !CoverReader.has(flac));

        section("格式识别");
        check("JPEG 能被 CoverArt 认", CoverArt.isJpeg(jpeg));
        check("PNG 能被 CoverArt 认", CoverArt.isPng(png));
        check("不存在文件安全", CoverReader.read(new File(work, "nope.mp3")) == null);

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------
    // 最小可写文件（结构与 TagRoundTripTest 一致）
    // ------------------------------------------------------------------

    private static void writeMp3(File f) throws Exception {
        byte[] frame = new byte[417];
        frame[0] = (byte) 0xFF;
        frame[1] = (byte) 0xFB;
        frame[2] = (byte) 0x90;
        frame[3] = 0x64;
        FileOutputStream out = new FileOutputStream(f);
        out.write(frame);
        out.write(new byte[417]);
        out.close();
    }

    private static void writeFlac(File f) throws Exception {
        FileOutputStream out = new FileOutputStream(f);
        out.write(new byte[]{'f', 'L', 'a', 'C'});
        // STREAMINFO（34 字节）+ last 标记
        byte[] si = new byte[34];
        out.write(0x80); // last=1, type=0
        out.write(0x00);
        out.write(0x00);
        out.write(si.length);
        out.write(si);
        out.write(new byte[64]);
        out.close();
    }

    static byte[] fakeJpeg(int w, int h) {
        byte[] sof = new byte[]{
                (byte) 0xFF, (byte) 0xC0, 0x00, 0x11, 0x08,
                (byte) ((h >> 8) & 0xFF), (byte) (h & 0xFF),
                (byte) ((w >> 8) & 0xFF), (byte) (w & 0xFF),
                0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
        };
        byte[] out = new byte[2 + sof.length + 2];
        out[0] = (byte) 0xFF;
        out[1] = (byte) 0xD8;
        System.arraycopy(sof, 0, out, 2, sof.length);
        out[out.length - 2] = (byte) 0xFF;
        out[out.length - 1] = (byte) 0xD9;
        return out;
    }

    static byte[] fakePng(int w, int h) {
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
