import com.dsh.musicorganizer.core.Ape;
import com.dsh.musicorganizer.core.TagIO;
import com.dsh.musicorganizer.core.Tags;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * APEv2 标签读写回归（纯 JVM）。
 *
 * <p>APE 的标签挂在文件尾，加标签不用搬音频，但三个地方极易写错：
 * <ul>
 *   <li>footer 的 tagSize 是「项 + footer」的总长，少算 32 字节就会把音频末尾吃掉；</li>
 *   <li>flags 声称有 header 却没写 header → 解析起点偏移，整段标签变乱码；</li>
 *   <li>文件尾常带 ID3v1（车载设备读它），重写时必须原样接回去。</li>
 * </ul>
 */
public class ApeTagTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) throws Exception {
        File dir = new File(args.length > 0 ? args[0] : "build/apefixtures");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();

        File ape = new File(dir, "plain.ape");
        byte[] audio = new byte[1000];
        for (int i = 0; i < audio.length; i++) {
            audio[i] = (byte) (i * 7);
        }
        writeApe(ape, audio, null, false);

        check("识别为 APE", Ape.isApe(ape));
        check("TagIO 支持写 .ape", TagIO.canWrite(".ape"));
        check("初始无标签", !Ape.read(ape).anyValue());

        Map<String, String> values = new LinkedHashMap<String, String>();
        values.put("title", "加州旅馆");
        values.put("artist", "Eagles");
        values.put("album", "Hotel California");
        values.put("year", "1976");
        values.put("track", "1");
        values.put("genre", "Rock");
        Ape.rewrite(ape, values, null);

        Tags t = Ape.read(ape);
        check("标题回读", "加州旅馆".equals(t.get("title")));
        check("歌手回读", "Eagles".equals(t.get("artist")));
        check("专辑回读", "Hotel California".equals(t.get("album")));
        check("年份回读", "1976".equals(t.get("year")));
        check("音轨回读", "1".equals(t.get("track")));
        check("流派回读", "Rock".equals(t.get("genre")));
        check("音频段未被改动", audioSame(ape, audio));

        // 二次写入：替换而不是叠加
        values.put("title", "加州旅馆（现场）");
        Ape.rewrite(ape, values, null);
        check("二次写入标题更新", "加州旅馆（现场）".equals(Ape.read(ape).get("title")));
        check("二次写入只有一个标签", countMagic(ape) == 1);
        check("二次写入音频仍完好", audioSame(ape, audio));

        // ID3v1 保留
        File withV1 = new File(dir, "withv1.ape");
        writeApe(withV1, audio, null, true);
        check("带 ID3v1 的文件可识别", Ape.isApe(withV1));
        Ape.rewrite(withV1, values, null);
        check("写后 ID3v1 仍在", hasId3v1(withV1));
        check("写后音频完好", audioSame(withV1, audio));

        // 保留自定义键（合并语义）
        File custom = new File(dir, "custom.ape");
        Map<String, String> extra = new LinkedHashMap<String, String>();
        extra.put("Album Artist", "Various");
        extra.put("Title", "旧标题");
        writeApe(custom, audio, extra, false);
        check("自定义键可读", "Various".equals(Ape.readRaw(custom, "Album Artist")));
        Map<String, String> upd = new LinkedHashMap<String, String>();
        upd.put("title", "新标题");
        Ape.rewrite(custom, upd, null);
        check("写入后自定义键保留", "Various".equals(Ape.readRaw(custom, "Album Artist")));
        check("写入后标题已改", "新标题".equals(Ape.read(custom).get("title")));

        // 封面
        File cov = new File(dir, "cover.ape");
        writeApe(cov, audio, null, false);
        check("初始无封面", !Ape.hasCover(cov));
        byte[] img = new byte[64];
        for (int i = 0; i < img.length; i++) {
            img[i] = (byte) (0xFF - i);
        }
        Ape.rewrite(cov, values, img);
        check("写入后有封面", Ape.hasCover(cov));
        check("写封面后标题仍在", "加州旅馆（现场）".equals(Ape.read(cov).get("title")));

        // 非 APE 拒绝
        File fake = new File(dir, "fake.ape");
        FileOutputStream f = new FileOutputStream(fake);
        f.write("just some bytes".getBytes("UTF-8"));
        f.close();
        check("非 APE 不误判", !Ape.isApe(fake));
        check("非 APE 写入报错", !TagIO.writeLocal(fake, values, null).isEmpty());

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    /** 造最小 APE：MAC 头 + 音频 + 可选 APE 标签 + 可选 ID3v1。 */
    private static void writeApe(File file, byte[] audio, Map<String, String> tag,
                                 boolean withId3v1) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write("MAC ".getBytes("US-ASCII"));
        out.write(audio);
        if (tag != null && !tag.isEmpty()) {
            out.write(buildTag(tag));
        }
        if (withId3v1) {
            byte[] v1 = new byte[128];
            v1[0] = 'T';
            v1[1] = 'A';
            v1[2] = 'G';
            byte[] title = "ID3V1 TITLE".getBytes("UTF-8");
            System.arraycopy(title, 0, v1, 3, title.length);
            out.write(v1);
        }
        FileOutputStream f = new FileOutputStream(file);
        try {
            f.write(out.toByteArray());
        } finally {
            f.close();
        }
    }

    private static byte[] buildTag(Map<String, String> tag) throws Exception {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        for (Map.Entry<String, String> e : tag.entrySet()) {
            byte[] key = e.getKey().getBytes("US-ASCII");
            byte[] value = e.getValue().getBytes("UTF-8");
            body.write(le32(value.length));
            body.write(le32(0));
            body.write(key);
            body.write(0);
            body.write(value);
        }
        byte[] items = body.toByteArray();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(items);
        byte[] footer = new byte[32];
        System.arraycopy("APETAGEX".getBytes("US-ASCII"), 0, footer, 0, 8);
        putLe32(footer, 8, 2000);
        putLe32(footer, 12, items.length + 32);
        putLe32(footer, 16, tag.size());
        putLe32(footer, 20, 0); // 不带 header
        out.write(footer);
        return out.toByteArray();
    }

    private static boolean audioSame(File file, byte[] audio) throws Exception {
        RandomAccessFile r = new RandomAccessFile(file, "r");
        try {
            byte[] head = new byte[4 + audio.length];
            r.readFully(head);
            if (head[0] != 'M' || head[1] != 'A' || head[2] != 'C' || head[3] != ' ') {
                return false;
            }
            for (int i = 0; i < audio.length; i++) {
                if (head[4 + i] != audio[i]) {
                    return false;
                }
            }
            return true;
        } finally {
            r.close();
        }
    }

    private static int countMagic(File file) throws Exception {
        RandomAccessFile r = new RandomAccessFile(file, "r");
        try {
            byte[] all = new byte[(int) r.length()];
            r.readFully(all);
            int n = 0;
            for (int i = 0; i + 8 <= all.length; i++) {
                if (all[i] == 'A' && all[i + 1] == 'P' && all[i + 2] == 'E' && all[i + 3] == 'T'
                        && all[i + 4] == 'A' && all[i + 5] == 'G' && all[i + 6] == 'E'
                        && all[i + 7] == 'X') {
                    n++;
                }
            }
            return n;
        } finally {
            r.close();
        }
    }

    private static boolean hasId3v1(File file) throws Exception {
        RandomAccessFile r = new RandomAccessFile(file, "r");
        try {
            if (r.length() < 128) {
                return false;
            }
            r.seek(r.length() - 128);
            byte[] b = new byte[3];
            r.readFully(b);
            return b[0] == 'T' && b[1] == 'A' && b[2] == 'G';
        } finally {
            r.close();
        }
    }

    private static byte[] le32(long v) {
        byte[] out = new byte[4];
        putLe32(out, 0, v);
        return out;
    }

    private static void putLe32(byte[] b, int off, long v) {
        b[off] = (byte) (v & 0xFF);
        b[off + 1] = (byte) ((v >> 8) & 0xFF);
        b[off + 2] = (byte) ((v >> 16) & 0xFF);
        b[off + 3] = (byte) ((v >> 24) & 0xFF);
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
