import com.dsh.musicorganizer.core.Krc;
import com.dsh.musicorganizer.core.LyricsDoc;

import java.nio.charset.StandardCharsets;
import java.util.List;

/**
 * 酷狗 KRC 回归（纯 JVM，v0.1.41 起，v0.1.44 补真实样本）。
 *
 * <p>三件事分开验：
 * <ul>
 *   <li><b>真实线上样本</b>（{@code tools/fixtures/krc_real.b64}）：证明密钥与偏移是对的。
 *       这一条 v0.1.41 漏了 —— 当时「自造样本往返」全绿，线上却解不开，因为打包和解包
 *       共用同一个（错误的 8 字节）密钥，错也自洽。<b>所以自造样本永远不能当作密钥正确的证据。</b></li>
 *   <li><b>解码按格式文档实现</b>：自己「打包」（zlib + krc1 头 + XOR）再解回来，
 *       保证实现与文档一致；</li>
 *   <li><b>KRC 文本 → 增强型 LRC</b>：行首时间、逐字三元组、元信息、无逐字的行都要对。</li>
 * </ul>
 */
public class KrcTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 0) 真实线上样本（args[0] 是 fixtures 目录）
        if (args.length > 0) {
            checkRealSample(args[0]);
        }
        // 1) 识别与 base64
        check("base64 魔数识别", Krc.looksEncoded("a3JjMTjbJCCT"));
        check("非 base64 不认", !Krc.looksEncoded("晴天"));
        check("null 不认", !Krc.looksEncoded(null));
        check("普通 base64 解码", new String(Krc.decodeBase64("aGVsbG8="),
                StandardCharsets.UTF_8).equals("hello"));
        check("无填充也能解", new String(Krc.decodeBase64("aGVsbG8"),
                StandardCharsets.UTF_8).equals("hello"));
        check("忽略换行", new String(Krc.decodeBase64("aGVs\nbG8="),
                StandardCharsets.UTF_8).equals("hello"));
        check("无填充长度 2 剩余",
                Krc.decodeBase64("YQ==").length == 1);
        check("空串返回空数组", Krc.decodeBase64("").length == 0);
        check("null 返回 null", Krc.decodeBase64(null) == null);

        // 2) 打包 → 解包往返（文档格式）
        String plain = "[id:$00000000]\n[ar:周杰伦]\n[ti:晴天]\n"
                + "[0,1000]<0,300,0>故<300,300,0>事<600,400,0>的\n"
                + "[1000,900]<0,450,0>小<450,450,0>黄<0,0,0>花";
        String packed = Krc.encodeForTest(plain);
        check("打包后是 base64", Krc.looksEncoded(packed));
        check("解包往返一致", Krc.decode(packed).equals(plain));

        // 3) 坏数据不抛异常
        check("乱码返回空", Krc.decode("这不是base64").isEmpty());
        check("空串返回空", Krc.decode("").isEmpty());
        check("null 返回空", Krc.decode(null).isEmpty());
        check("短数据返回空", Krc.decode("a3Jj").isEmpty());

        // 4) KRC 文本 → 增强型 LRC
        String enhanced = Krc.toEnhancedLrc(plain);
        check("保留 ar 元信息", enhanced.contains("[ar:周杰伦]"));
        check("保留 id 元信息", enhanced.contains("[id:$00000000]"));
        check("行首时间转换", enhanced.contains("[00:00.00]<00:00.00>故"));
        check("逐字时间累加", enhanced.contains("<00:00.30>事"));
        check("第三个字", enhanced.contains("<00:00.60>的"));
        check("第二行行首", enhanced.contains("[00:01.00]<00:01.00>小"));
        check("第二行第二个字", enhanced.contains("<00:01.45>黄"));
        check("空文本不炸", Krc.toEnhancedLrc("").isEmpty());
        check("null 不炸", Krc.toEnhancedLrc(null).isEmpty());

        // 5) 没有逐字信息的行只输出行时间
        String plainLine = Krc.toEnhancedLrc("[5000,2000]这一行没有逐字");
        check("无逐字行", plainLine.equals("[00:05.00]这一行没有逐字"));

        // 6) 转出来的增强型 LRC 能被 LyricsDoc 反解（界面/时间轴都靠它）
        List<LyricsDoc.Line> lines = LyricsDoc.parse(enhanced);
        check("反解出两行", lines.size() == 2);
        check("第一行逐字 3 个", lines.get(0).words.size() == 3);
        check("第一行文本", lines.get(0).text.equals("故事的"));
        check("第一行时间", lines.get(0).timeMs == 0);
        check("第二行时间", lines.get(1).timeMs == 1000);

        // 7) 毫秒精度：超过 1 分钟要进位
        String longLine = Krc.toEnhancedLrc("[125340,1000]<0,500,0>晚");
        check("分钟进位", longLine.startsWith("[02:05.34]"));

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    /**
     * 真实线上样本验证。样本是 2026-10-23 从 {@code lyrics.kugou.com/download?fmt=krc}
     * 实际取回的「周杰伦 - 晴天 (DJ 阿若版)」，原样保存的 base64。
     */
    private static void checkRealSample(String dir) {
        java.io.File f = new java.io.File(dir, "krc_real.b64");
        if (!f.isFile()) {
            System.out.println("  skip 真实样本缺失（" + f.getPath() + "），跳过线上验证");
            return;
        }
        String b64;
        try {
            b64 = new String(java.nio.file.Files.readAllBytes(f.toPath()),
                    StandardCharsets.UTF_8).trim();
        } catch (Exception e) {
            check("真实样本可读", false);
            return;
        }
        String plain = Krc.decode(b64);
        check("真实样本解得出（密钥正确）", plain.length() > 1000);
        check("真实样本含艺人元信息", plain.contains("[ar:"));
        check("真实样本含逐字三元组", plain.indexOf("]<0,") > 0);
        String lrc = Krc.toEnhancedLrc(plain);
        check("真实样本转成 LRC", lrc.contains("[00:"));
        check("真实样本转出逐字标记", lrc.contains("<00:"));
        check("真实样本行数不变",
                plain.split("\n").length == lrc.split("\n").length);
        check("真实样本首行是 ti 元信息", plain.startsWith("[ti:"));
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
