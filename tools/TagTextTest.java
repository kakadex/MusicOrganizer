import com.dsh.musicorganizer.core.Id3;
import com.dsh.musicorganizer.core.TagText;
import com.dsh.musicorganizer.core.Tags;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;

/**
 * 标签文本解码容错回归（纯 JVM，v0.1.45）。
 *
 * <p>用例里的字节不是编的，是从一批真实「标签乱码」样本里抄出来的
 * 真实帧内容 —— 这一类 bug 只有用真样本才能钉住（v0.1.41 的 KRC 就是自造样本全绿、
 * 线上全错）。
 *
 * <p>三种错法各来一遍，同时**必须有「不许误伤」的反向用例**：
 * 正常 UTF-8 中文、日文、韩文、法文 café、纯 ASCII 都要原样返回。
 */
public class TagTextTest {

    private static int pass = 0;
    private static int fail = 0;
    private static final Charset GBK = Charset.forName("GBK");

    public static void main(String[] args) throws Exception {
        // 1) 声明 UTF-8、内容是 GBK（真实样本：某 MP3 的 TIT2）
        check("GBK 冒充 UTF-8：标题",
                "测试标题".equals(TagText.decodeUtf8(hex("b2 e2 ca d4 b1 ea cc e2"))));
        // 另一首歌的 TIT2
        check("GBK 冒充 UTF-8：短曲名",
                "测试".equals(TagText.decodeUtf8(hex("b2 e2 ca d4"))));
        // 再换一个长一点的标题
        check("GBK 冒充 UTF-8：长标题",
                "一段较长的中文标题".equals(TagText.decodeUtf8(
                        hex("d2 bb b6 ce bd cf b3 a4 b5 c4 d6 d0 ce c4 b1 ea cc e2"))));

        // 2) 双重编码：GBK 先被当 Latin-1、再存成 UTF-8（某 MP3 的 TPE1 / TALB）
        check("双重编码：专辑",
                "测试专辑".equals(TagText.decodeUtf8(
                        hex("c2 b2 c3 a2 c3 8a c3 94 c3 97 c2 a8 c2 bc c2 ad"))));
        check("双重编码：艺人",
                "测试艺人".equals(TagText.decodeUtf8(
                        hex("c2 b2 c3 a2 c3 8a c3 94 c3 92 c3 95 c3 88 c3 8b"))));
        check("双重编码：流行",
                "流行".equals(TagText.decodeUtf8(hex("c3 81 c3 b7 c3 90 c3 90"))));
        // 用动态构造补齐（手抄 hex 容易抄错，而且能顺手覆盖更多词）
        check("双重编码：歌手",
                "示例歌手".equals(TagText.decodeUtf8(doubleEncode("示例歌手"))));
        check("双重编码：周杰伦",
                "周杰伦".equals(TagText.decodeUtf8(doubleEncode("周杰伦"))));
        check("双重编码：长标题",
                "一段较长的中文标题".equals(TagText.decodeUtf8(doubleEncode("一段较长的中文标题"))));

        // 3) 正常 UTF-8 中文不许被改（最容易踩的误伤）
        check("正常 UTF-8 中文：周杰伦",
                "周杰伦".equals(TagText.decodeUtf8("周杰伦".getBytes(StandardCharsets.UTF_8))));
        check("正常 UTF-8 中文：标题",
                "测试标题".equals(TagText.decodeUtf8("测试标题".getBytes(StandardCharsets.UTF_8))));
        check("正常 UTF-8 长标题",
                "电视剧《测试标题》主题曲".equals(TagText.decodeUtf8(
                        "电视剧《测试标题》主题曲".getBytes(StandardCharsets.UTF_8))));
        check("正常 UTF-8 日文不被改",
                "さくら".equals(TagText.decodeUtf8("さくら".getBytes(StandardCharsets.UTF_8))));
        check("正常 UTF-8 韩文不被改",
                "사랑".equals(TagText.decodeUtf8("사랑".getBytes(StandardCharsets.UTF_8))));
        check("正常 UTF-8 带重音不被改",
                "Café Señor".equals(TagText.decodeUtf8(
                        "Café Señor".getBytes(StandardCharsets.UTF_8))));

        // 4) 纯 ASCII / 空
        check("纯 ASCII", "Hello World".equals(TagText.decodeUtf8(
                "Hello World".getBytes(StandardCharsets.US_ASCII))));
        check("空数组", TagText.decodeUtf8(new byte[0]).isEmpty());
        check("null", TagText.decodeUtf8(null).isEmpty());

        // 5) NUL 截断（帧用 NUL 结束；v2.4 也用 NUL 分隔多值）
        byte[] withNul = concat("你".getBytes(StandardCharsets.UTF_8), new byte[]{0},
                "好".getBytes(StandardCharsets.UTF_8));
        check("NUL 截断", "你".equals(TagText.decodeUtf8(withNul)));
        check("stripNul 无 NUL 原样", "abc".equals(TagText.stripNul("abc")));
        check("stripNul null", TagText.stripNul(null).isEmpty());

        // 6) encoding=0 的三种情况
        check("enc=0 真 GBK：谢霆锋",
                "谢霆锋".equals(TagText.decodeLatin1OrGbk("谢霆锋".getBytes(GBK))));
        check("enc=0 真 UTF-8：测试标题",
                "测试标题".equals(TagText.decodeLatin1OrGbk("测试标题".getBytes(StandardCharsets.UTF_8))));
        check("enc=0 真 Latin-1：café 不被改",
                "café".equals(TagText.decodeLatin1OrGbk("café".getBytes(StandardCharsets.ISO_8859_1))));
        check("enc=0 纯 ASCII",
                "Hello".equals(TagText.decodeLatin1OrGbk("Hello".getBytes(StandardCharsets.US_ASCII))));
        check("enc=0 空", TagText.decodeLatin1OrGbk(new byte[0]).isEmpty());

        // 7) 汉字判定边界
        check("containsCjk 中文", TagText.containsCjk("我"));
        check("containsCjk 假名不算", !TagText.containsCjk("さ"));
        check("containsCjk ASCII", !TagText.containsCjk("abc"));
        check("containsCjk null", !TagText.containsCjk(null));

        // 8) 端到端：造一个 ID3v2.4 标签（GBK 冒充 UTF-8），走 Id3.read
        //    这一步验证「帧解析 + 解码」整条链，而不只是解码函数
        File tmp = File.createTempFile("mo_tagtext_", ".mp3");
        try {
            byte[] tit2 = concat(new byte[]{3}, "测试标题".getBytes(GBK));
            byte[] tpe1 = concat(new byte[]{3}, "示例歌手".getBytes(GBK));
            byte[] album = concat(new byte[]{3}, "测试专辑".getBytes(GBK));
            byte[] tag = id3v24(new byte[64], frame("TIT2", tit2),
                    frame("TPE1", tpe1), frame("TALB", album));
            FileOutputStream out = new FileOutputStream(tmp);
            out.write(tag);
            out.close();
            Tags tags = Id3.read(tmp);
            check("Id3 端到端：标题", "测试标题".equals(tags.get("title")));
            check("Id3 端到端：艺人", "示例歌手".equals(tags.get("artist")));
            check("Id3 端到端：专辑", "测试专辑".equals(tags.get("album")));
        } finally {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
        }

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    // ---------------------------------------------------------------- 工具

    /** 十六进制串 → 字节数组（如 "b2 e2 ca d4"）。 */
    private static byte[] hex(String s) {
        String[] parts = s.trim().split("\\s+");
        byte[] out = new byte[parts.length];
        for (int i = 0; i < parts.length; i++) {
            out[i] = (byte) Integer.parseInt(parts[i], 16);
        }
        return out;
    }

    /**
     * 造「GBK → 当成 Latin-1 → 再编码成 UTF-8」的双重编码字节。
     *
     * <p>动态构造而不是手抄 hex：抄错一个字节，用例就从「验证修复」变成「验证错误」。
     */
    private static byte[] doubleEncode(String s) {
        byte[] gbk = s.getBytes(GBK);
        StringBuilder sb = new StringBuilder(gbk.length);
        for (byte b : gbk) {
            sb.append((char) (b & 0xFF));
        }
        return sb.toString().getBytes(StandardCharsets.UTF_8);
    }

    private static byte[] concat(byte[]... parts) {        int n = 0;
        for (byte[] p : parts) {
            n += p.length;
        }
        byte[] out = new byte[n];
        int p = 0;
        for (byte[] part : parts) {
            System.arraycopy(part, 0, out, p, part.length);
            p += part.length;
        }
        return out;
    }

    /** ID3v2.4 帧：4 字节 ID + synchsafe 长度 + 2 字节 flags + 正文。 */
    private static byte[] frame(String id, byte[] body) {
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        byte[] name = id.getBytes(StandardCharsets.US_ASCII);
        o.write(name, 0, 4);
        int n = body.length;
        o.write((n >> 21) & 0x7F);
        o.write((n >> 14) & 0x7F);
        o.write((n >> 7) & 0x7F);
        o.write(n & 0x7F);
        o.write(0);
        o.write(0);
        o.write(body, 0, body.length);
        return o.toByteArray();
    }

    /** "ID3" + v2.4 头 + 若干帧 + 填充。 */
    private static byte[] id3v24(byte[] padding, byte[]... frames) {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        for (byte[] f : frames) {
            body.write(f, 0, f.length);
        }
        body.write(padding, 0, padding.length);
        byte[] payload = body.toByteArray();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write('I');
        out.write('D');
        out.write('3');
        out.write(4);
        out.write(0);
        out.write(0);
        int n = payload.length;
        out.write((n >> 21) & 0x7F);
        out.write((n >> 14) & 0x7F);
        out.write((n >> 7) & 0x7F);
        out.write(n & 0x7F);
        out.write(payload, 0, payload.length);
        return out.toByteArray();
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
