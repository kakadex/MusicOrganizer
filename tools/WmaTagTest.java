import com.dsh.musicorganizer.core.TagIO;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.Wma;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;

/**
 * WMA（ASF）只读标签回归（纯 JVM）。
 *
 * <p>ASF 头是「对象套对象 + 每层自带长度」，最容易错的是两个长度字段的宽度
 * （对象大小是 8 字节 QWORD，Content Description 里的字符串长度是 2 字节 WORD）。
 */
public class WmaTagTest {

    private static int pass = 0;
    private static int fail = 0;

    private static final byte[] GUID_HEADER = {
            0x30, 0x26, (byte) 0xB2, 0x75, (byte) 0x8E, 0x66, (byte) 0xCF, 0x11,
            (byte) 0xA6, (byte) 0xD9, 0x00, (byte) 0xAA, 0x00, 0x62, (byte) 0xCE, 0x6C
    };
    private static final byte[] GUID_CONTENT = {
            0x33, 0x26, (byte) 0xB2, 0x75, (byte) 0x8E, 0x66, (byte) 0xCF, 0x11,
            (byte) 0xA6, (byte) 0xD9, 0x00, (byte) 0xAA, 0x00, 0x62, (byte) 0xCE, 0x6C
    };
    private static final byte[] GUID_EXT = {
            0x40, (byte) 0xA4, (byte) 0xD0, (byte) 0xD2, 0x07, (byte) 0xE3, (byte) 0xD2, 0x11,
            (byte) 0x97, (byte) 0xF0, 0x00, (byte) 0xA0, (byte) 0xC9, 0x5E, (byte) 0xA8, 0x50
    };

    public static void main(String[] args) throws Exception {
        File dir = new File(args.length > 0 ? args[0] : "build/wmafixtures");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        File wma = new File(dir, "sample.wma");
        writeWma(wma);

        check("识别为 WMA", Wma.isWma(wma));
        Tags t = Wma.read(wma);
        check("标题来自 Content Description", "晴天".equals(t.get("title")));
        check("歌手来自 Content Description", "周杰伦".equals(t.get("artist")));
        check("专辑来自扩展项", "叶惠美".equals(t.get("album")));
        check("流派来自扩展项", "Pop".equals(t.get("genre")));
        check("年份来自扩展项", "2003".equals(t.get("year")));
        check("音轨来自扩展项", "3".equals(t.get("track")));

        check("WMA 不声明可写", !TagIO.canWrite(".wma"));
        check("写 WMA 返回提示", !TagIO.writeLocal(wma, new java.util.LinkedHashMap<String, String>(), null).isEmpty());
        check("TagIO 能读 WMA 标题", "晴天".equals(TagIO.readLocal(wma).get("title")));

        File fake = new File(dir, "fake.wma");
        FileOutputStream f = new FileOutputStream(fake);
        f.write("not asf".getBytes("UTF-8"));
        f.close();
        check("非 WMA 不误判", !Wma.isWma(fake));
        check("非 WMA 读不到标签", !Wma.read(fake).anyValue());

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    private static void writeWma(File file) throws Exception {
        ByteArrayOutputStream content = new ByteArrayOutputStream();
        String[] cd = {"晴天", "周杰伦", "", "选自专辑", ""};
        byte[] title = Wma.utf16Bytes(cd[0]);
        byte[] author = Wma.utf16Bytes(cd[1]);
        byte[] copyright = Wma.utf16Bytes(cd[2]);
        byte[] desc = Wma.utf16Bytes(cd[3]);
        byte[] rating = Wma.utf16Bytes(cd[4]);
        ByteArrayOutputStream cbody = new ByteArrayOutputStream();
        cbody.write(word(title.length));
        cbody.write(word(author.length));
        cbody.write(word(copyright.length));
        cbody.write(word(desc.length));
        cbody.write(word(rating.length));
        cbody.write(title);
        cbody.write(author);
        cbody.write(copyright);
        cbody.write(desc);
        cbody.write(rating);

        ByteArrayOutputStream ext = new ByteArrayOutputStream();
        ext.write(word(4)); // 四个扩展项（音轨用 DWORD 型，验证数值型解析）
        writeExtString(ext, "WM/AlbumTitle", "叶惠美");
        writeExtString(ext, "WM/Genre", "Pop");
        writeExtString(ext, "WM/Year", "2003");
        writeExtDword(ext, "WM/TrackNumber", 3);

        byte[] contentObj = object(GUID_CONTENT, cbody.toByteArray());
        byte[] extObj = object(GUID_EXT, ext.toByteArray());

        int headerSize = 30 + contentObj.length + extObj.length;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(GUID_HEADER);
        out.write(qword(headerSize));
        out.write(dword(2)); // 两个子对象
        out.write(1);
        out.write(2);
        out.write(contentObj);
        out.write(extObj);
        // 数据对象（解析只读头部，随便给点字节）
        out.write(new byte[64]);
        FileOutputStream f = new FileOutputStream(file);
        try {
            f.write(out.toByteArray());
        } finally {
            f.close();
        }
    }

    private static void writeExtString(ByteArrayOutputStream out, String name, String value)
            throws Exception {
        byte[] n = Wma.utf16Bytes(name);
        byte[] v = Wma.utf16Bytes(value);
        out.write(word(n.length));
        out.write(n);
        out.write(word(0)); // type = 字符串
        out.write(word(v.length));
        out.write(v);
    }

    private static void writeExtDword(ByteArrayOutputStream out, String name, long value)
            throws Exception {
        byte[] n = Wma.utf16Bytes(name);
        out.write(word(n.length));
        out.write(n);
        out.write(word(3)); // type = DWORD
        out.write(word(4));
        out.write(dword(value));
    }


    private static byte[] object(byte[] guid, byte[] body) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(guid);
        out.write(qword(24 + body.length));
        out.write(body);
        return out.toByteArray();
    }

    private static byte[] word(int v) {
        return new byte[]{(byte) (v & 0xFF), (byte) ((v >> 8) & 0xFF)};
    }

    private static byte[] dword(long v) {
        return new byte[]{(byte) (v & 0xFF), (byte) ((v >> 8) & 0xFF),
                (byte) ((v >> 16) & 0xFF), (byte) ((v >> 24) & 0xFF)};
    }

    private static byte[] qword(long v) {
        byte[] out = new byte[8];
        for (int i = 0; i < 8; i++) {
            out[i] = (byte) ((v >> (8 * i)) & 0xFF);
        }
        return out;
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            pass++;
            System.out.println("  ok   " + name);
        } else {
            fail++;
            System.out.println("  FAIL " + name);
        }
    }
}
