import com.dsh.musicorganizer.core.*;
import java.io.*;
import java.util.*;

/** 离线回归测试：ID3 合并写入 + USLT 歌词嵌入 + FLAC LYRICS。 */
public class TagRoundTripTest {
    static int fails = 0;
    static void check(String name, String expect, String actual) {
        boolean ok = expect.equals(actual);
        if (!ok) fails++;
        System.out.println((ok ? "  ok   " : "  FAIL ") + name
                + (ok ? "" : "  期望=[" + expect + "] 实际=[" + actual + "]"));
    }

    static File mkMp3(File dir, String name) throws Exception {
        File f = new File(dir, name);
        FileOutputStream out = new FileOutputStream(f);
        for (int i = 0; i < 2048; i++) out.write(0xFF);   // 伪音频，只需字节流
        out.close();
        return f;
    }

    /** 最小合法 JPEG（含 SOF0，带尺寸）。 */
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

    /** 最小 PNG 头（含 IHDR 尺寸）。 */
    static byte[] fakePng(int w, int h) {
        return new byte[]{(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A,
                0, 0, 0, 13, 'I', 'H', 'D', 'R',
                (byte) (w >> 24), (byte) (w >> 16), (byte) (w >> 8), (byte) w,
                (byte) (h >> 24), (byte) (h >> 16), (byte) (h >> 8), (byte) h,
                8, 6, 0, 0, 0};
    }

    public static void main(String[] a) throws Exception {
        File dir = new File(a[0]);
        dir.mkdirs();

        System.out.println("[1] ID3v2.3 首次写入全字段");
        File mp3 = mkMp3(dir, "t.mp3");
        Map<String,String> all = new LinkedHashMap<>();
        all.put("title", "原歌名"); all.put("artist", "原歌手");
        all.put("album", "原专辑"); all.put("year", "2020");
        all.put("track", "3"); all.put("genre", "Pop"); all.put("comment", "备注");
        Id3.rewrite(mp3, all);
        Tags t = Id3.read(mp3);
        check("title", "原歌名", t.get("title"));
        check("artist", "原歌手", t.get("artist"));
        check("album", "原专辑", t.get("album"));
        check("year", "2020", t.get("year"));

        System.out.println("[2] 只改 title —— 其余字段必须保留（合并语义）");
        Map<String,String> one = new HashMap<>();
        one.put("title", "新歌名");
        Id3.rewrite(mp3, one);
        t = Id3.read(mp3);
        check("title", "新歌名", t.get("title"));
        check("artist 保留", "原歌手", t.get("artist"));
        check("album 保留", "原专辑", t.get("album"));
        check("genre 保留", "Pop", t.get("genre"));

        System.out.println("[3] 只写歌词 —— 其它字段与音频长度不变");
        long before = mp3.length();
        Map<String,String> lyr = new HashMap<>();
        String text = "[00:01.00]第一行\n[00:05.50]第二行 中文";
        lyr.put("lyrics", text);
        Id3.rewrite(mp3, lyr);
        t = Id3.read(mp3);
        check("lyrics", text, t.get("lyrics"));
        check("title 保留", "新歌名", t.get("title"));
        check("artist 保留", "原歌手", t.get("artist"));
        System.out.println("  音频尾部长度变化 = " + (mp3.length() - before) + " 字节（仅标签增长，属正常）");

        System.out.println("[4] 清除歌词（空字符串）");
        Map<String,String> clr = new HashMap<>();
        clr.put("lyrics", "");
        Id3.rewrite(mp3, clr);
        t = Id3.read(mp3);
        check("lyrics 已清空", "", t.get("lyrics"));
        check("album 仍保留", "原专辑", t.get("album"));

        System.out.println("[5] FLAC LYRICS 写入 + 其它 Vorbis 注释保留");
        File flac = new File(dir, "t.flac");
        FileOutputStream fo = new FileOutputStream(flac);
        fo.write(new byte[]{'f','L','a','C'});
        fo.write(0x80); fo.write(0); fo.write(0); fo.write(34);   // STREAMINFO, last=true
        fo.write(new byte[34]);
        for (int i = 0; i < 4096; i++) fo.write(0x11);
        fo.close();
        Map<String,String> f1 = new LinkedHashMap<>();
        f1.put("title", "F歌名"); f1.put("artist", "F歌手");
        Flac.rewrite(flac, f1);
        check("flac title", "F歌名", Flac.read(flac).get("title"));
        Map<String,String> f2 = new HashMap<>();
        f2.put("lyrics", text);
        Flac.rewrite(flac, f2);
        Tags ft = Flac.read(flac);
        check("flac lyrics", text, ft.get("lyrics"));
        check("flac artist 保留", "F歌手", ft.get("artist"));

        System.out.println("[6] MP3 封面（APIC）写入 / 替换 / 删除");
        byte[] jpeg = fakeJpeg(120, 90);
        check("初始无封面", "false", String.valueOf(Id3.hasCover(mp3)));
        Id3.rewrite(mp3, new HashMap<String, String>(), jpeg);
        check("写入后有封面", "true", String.valueOf(Id3.hasCover(mp3)));
        check("写封面不动标题", "新歌名", Id3.read(mp3).get("title"));
        byte[] png = fakePng(200, 200);
        Id3.rewrite(mp3, new HashMap<String, String>(), png);
        check("替换后仍有封面", "true", String.valueOf(Id3.hasCover(mp3)));
        check("替换后标题仍在", "新歌名", Id3.read(mp3).get("title"));
        Id3.rewrite(mp3, new HashMap<String, String>(), new byte[0]);
        check("空数组删除封面", "false", String.valueOf(Id3.hasCover(mp3)));
        check("删封面后标题仍在", "新歌名", Id3.read(mp3).get("title"));

        System.out.println("[7] FLAC 封面（PICTURE 块）写入 / 删除");
        check("初始无封面块", "false", String.valueOf(Flac.hasPicture(flac)));
        Flac.rewrite(flac, new HashMap<String, String>(), jpeg);
        check("写入后有封面块", "true", String.valueOf(Flac.hasPicture(flac)));
        check("写封面不动标题", "F歌名", Flac.read(flac).get("title"));
        check("写封面不动歌词", text, Flac.read(flac).get("lyrics"));
        Flac.rewrite(flac, new HashMap<String, String>(), new byte[0]);
        check("空数组删除封面块", "false", String.valueOf(Flac.hasPicture(flac)));

        System.out.println(fails == 0 ? "\n全部通过 ✅" : "\n失败 " + fails + " 项 ❌");
        if (fails != 0) System.exit(1);
    }
}
