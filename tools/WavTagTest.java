import com.dsh.musicorganizer.core.TagIO;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.Wav;

import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * WAV 标签读写回归（纯 JVM）。
 *
 * <p>WAV 的坑集中在两处，测试必须盯住：
 * <ul>
 *   <li><b>chunk 对齐</b>：奇数长度要补 1 字节，否则后面的 chunk 全部错位；</li>
 *   <li><b>RIFF 长度</b>：写在文件头第 4 字节，改文件长度后不回填，部分播放器会拒绝播放。</li>
 * </ul>
 */
public class WavTagTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) throws Exception {
        File dir = new File(args.length > 0 ? args[0] : "build/wavfixtures");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();

        // 1) 造一个最小合法 WAV（PCM 单声道 8kHz，1KB 数据，内容是递增字节，便于校验没被改）
        File wav = new File(dir, "plain.wav");
        byte[] pcm = new byte[1024];
        for (int i = 0; i < pcm.length; i++) {
            pcm[i] = (byte) i;
        }
        writeWav(wav, pcm, null);

        check("识别为 WAV", Wav.isWav(wav));
        check("TagIO 也认它为 WAV", TagIO.canWrite(".wav"));
        check("空 WAV 读不到标签", !Wav.read(wav).anyValue());

        // 2) 写全字段并回读
        Map<String, String> values = new LinkedHashMap<String, String>();
        values.put("title", "测试标题");
        values.put("artist", "张三");
        values.put("album", "专辑名");
        values.put("year", "2024");
        values.put("track", "3");
        values.put("genre", "Pop");
        values.put("comment", "备注");
        Wav.rewrite(wav, values, null);
        Tags t = Wav.read(wav);
        check("标题回读", "测试标题".equals(t.get("title")));
        check("歌手回读", "张三".equals(t.get("artist")));
        check("专辑回读", "专辑名".equals(t.get("album")));
        check("年份回读", "2024".equals(t.get("year")));
        check("音轨回读", "3".equals(t.get("track")));
        check("流派回读", "Pop".equals(t.get("genre")));

        // 3) 音频数据必须原样（一个字节都不能变）
        check("PCM 数据未被破坏", samePcm(readData(wav), pcm));
        check("RIFF 长度已回填", riffSizeOk(wav));

        // 4) 二次写入：不能出现两个 id3 块，且旧值被替换
        values.put("title", "新标题");
        Wav.rewrite(wav, values, null);
        check("只有一个 ID3 块", countId3(wav) == 1);
        check("二次写入标题已更新", "新标题".equals(Wav.read(wav).get("title")));
        check("二次写入其它字段保留", "张三".equals(Wav.read(wav).get("artist")));
        check("二次写入 PCM 仍完好", samePcm(readData(wav), pcm));

        // 5) 读 RIFF LIST/INFO 标签（老软件写的文件）
        File infoWav = new File(dir, "info.wav");
        Map<String, String> info = new LinkedHashMap<String, String>();
        info.put("INAM", "INFO 标题");
        info.put("IART", "INFO 歌手");
        writeWav(infoWav, pcm, info);
        Tags it = Wav.read(infoWav);
        check("INFO 标题可读", "INFO 标题".equals(it.get("title")));
        check("INFO 歌手可读", "INFO 歌手".equals(it.get("artist")));

        // 6) 覆盖 INFO 文件后：INFO 被清掉、只留 ID3
        Wav.rewrite(infoWav, values, null);
        check("INFO 已被清理", countChunk(infoWav, "LIST") == 0);
        check("留下一个 ID3", countId3(infoWav) == 1);
        check("新标签生效", "新标题".equals(Wav.read(infoWav).get("title")));
        check("INFO 文件 PCM 完好", samePcm(readData(infoWav), pcm));

        // 7) 走 TagIO 分发（批量任务实际走这条路径）
        File viaIo = new File(dir, "viaio.wav");
        writeWav(viaIo, pcm, null);
        String err = TagIO.writeLocal(viaIo, values, null);
        check("TagIO 写 WAV 无错误", err.isEmpty());
        check("TagIO 读 WAV 标题", "新标题".equals(TagIO.readLocal(viaIo).get("title")));

        // 8) 非 WAV 文件不能被误判
        File notWav = new File(dir, "fake.wav");
        FileOutputStream f = new FileOutputStream(notWav);
        f.write("not a wav file at all".getBytes("UTF-8"));
        f.close();
        check("非 WAV 不误判", !Wav.isWav(notWav));
        check("非 WAV 写入报错", !TagIO.writeLocal(notWav, values, null).isEmpty());

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    /** 造 WAV：可选插一个 LIST/INFO 块（放在 data 之前）。 */
    private static void writeWav(File file, byte[] pcm, Map<String, String> info)
            throws Exception {
        java.io.ByteArrayOutputStream body = new java.io.ByteArrayOutputStream();
        // fmt
        body.write("fmt ".getBytes("US-ASCII"));
        body.write(le32(16));
        body.write(le16(1));       // PCM
        body.write(le16(1));       // 单声道
        body.write(le32(8000));    // 采样率
        body.write(le32(16000));   // 字节率
        body.write(le16(2));       // block align
        body.write(le16(16));      // 位深
        // 可选 INFO
        if (info != null && !info.isEmpty()) {
            java.io.ByteArrayOutputStream sub = new java.io.ByteArrayOutputStream();
            for (Map.Entry<String, String> e : info.entrySet()) {
                byte[] v = (e.getValue() + "\0").getBytes("UTF-8");
                sub.write(e.getKey().getBytes("US-ASCII"));
                sub.write(le32(v.length));
                sub.write(v);
                if ((v.length & 1) == 1) {
                    sub.write(0);
                }
            }
            body.write("LIST".getBytes("US-ASCII"));
            body.write(le32(4 + sub.size()));
            body.write("INFO".getBytes("US-ASCII"));
            body.write(sub.toByteArray());
        }
        // data
        body.write("data".getBytes("US-ASCII"));
        body.write(le32(pcm.length));
        body.write(pcm);
        if ((pcm.length & 1) == 1) {
            body.write(0);
        }

        byte[] payload = body.toByteArray();
        FileOutputStream out = new FileOutputStream(file);
        try {
            out.write("RIFF".getBytes("US-ASCII"));
            out.write(le32(4 + payload.length));
            out.write("WAVE".getBytes("US-ASCII"));
            out.write(payload);
        } finally {
            out.close();
        }
    }

    private static byte[] readData(File file) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            long pos = 12;
            while (pos + 8 <= raf.length()) {
                raf.seek(pos);
                byte[] h = new byte[8];
                raf.readFully(h);
                String id = new String(h, 0, 4, "US-ASCII");
                long size = ((long) (h[4] & 0xFF)) | ((long) (h[5] & 0xFF) << 8)
                        | ((long) (h[6] & 0xFF) << 16) | ((long) (h[7] & 0xFF) << 24);
                if ("data".equals(id)) {
                    byte[] out = new byte[(int) size];
                    raf.seek(pos + 8);
                    raf.readFully(out);
                    return out;
                }
                pos = pos + 8 + size + (size & 1);
            }
            return new byte[0];
        } finally {
            raf.close();
        }
    }

    private static int countChunk(File file, String id) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            int n = 0;
            long pos = 12;
            while (pos + 8 <= raf.length()) {
                raf.seek(pos);
                byte[] h = new byte[8];
                raf.readFully(h);
                String got = new String(h, 0, 4, "US-ASCII");
                long size = ((long) (h[4] & 0xFF)) | ((long) (h[5] & 0xFF) << 8)
                        | ((long) (h[6] & 0xFF) << 16) | ((long) (h[7] & 0xFF) << 24);
                if (id.equals(got)) {
                    n++;
                }
                pos = pos + 8 + size + (size & 1);
            }
            return n;
        } finally {
            raf.close();
        }
    }

    private static int countId3(File file) throws Exception {
        // chunk id 大小写都算（有的软件写 "ID3 "）
        return countChunk(file, "id3 ") + countChunk(file, "ID3 ");
    }

    private static boolean riffSizeOk(File file) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            byte[] h = new byte[8];
            raf.readFully(h);
            long size = ((long) (h[4] & 0xFF)) | ((long) (h[5] & 0xFF) << 8)
                    | ((long) (h[6] & 0xFF) << 16) | ((long) (h[7] & 0xFF) << 24);
            return size == file.length() - 8;
        } finally {
            raf.close();
        }
    }

    private static boolean samePcm(byte[] a, byte[] b) {
        if (a.length != b.length) {
            return false;
        }
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    private static byte[] le16(long v) {
        return new byte[]{(byte) (v & 0xFF), (byte) ((v >> 8) & 0xFF)};
    }

    private static byte[] le32(long v) {
        return new byte[]{(byte) (v & 0xFF), (byte) ((v >> 8) & 0xFF),
                (byte) ((v >> 16) & 0xFF), (byte) ((v >> 24) & 0xFF)};
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
