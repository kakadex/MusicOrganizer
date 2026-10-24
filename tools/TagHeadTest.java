import com.dsh.musicorganizer.core.Flac;
import com.dsh.musicorganizer.core.Id3;
import com.dsh.musicorganizer.core.TagIO;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.HashMap;
import java.util.Map;

/**
 * 离线回归测试（纯 JVM）：读标签时的「头部够不够」判断。
 *
 * 为什么要测：为了不把整个音频复制到临时目录再读标签（一首 FLAC 30MB，
 * 批量几百首就是几 GB 的无谓读写），现在只复制前 2MB，再用
 * {@link TagIO#tagFitsCopy} 判断标签是否完整落在头部副本里。
 * 这个判断错了只有两种后果，都很严重：
 *   · 误判「够」→ 标签读不全，界面显示为空，可能重复写入；
 *   · 误判「不够」→ 每次回退整文件复制，优化白做。
 *
 * 覆盖：无 ID3 / 有 ID3 / 头部被截断 / FLAC 有 Vorbis Comment / FLAC 被截断。
 * 用 tools/run_tag_test.sh 跑。
 */
public class TagHeadTest {

    static int fails = 0;

    static void ok(String name, boolean cond) {
        if (!cond) {
            fails++;
        }
        System.out.println((cond ? "  ok   " : "  FAIL ") + name);
    }

    static File mkMp3(File dir, String name) throws Exception {
        File f = new File(dir, name);
        FileOutputStream out = new FileOutputStream(f);
        for (int i = 0; i < 4096; i++) {
            out.write(0xFF);
        }
        out.close();
        return f;
    }

    /** 取源文件前 n 字节，模拟「头部副本」。 */
    static File head(File src, File dir, String name, int n) throws Exception {
        File f = new File(dir, name);
        FileInputStream in = new FileInputStream(src);
        FileOutputStream out = new FileOutputStream(f);
        byte[] buf = new byte[Math.min(n, 65536)];
        int left = n;
        while (left > 0) {
            int got = in.read(buf, 0, Math.min(buf.length, left));
            if (got <= 0) {
                break;
            }
            out.write(buf, 0, got);
            left -= got;
        }
        in.close();
        out.close();
        return f;
    }

    public static void main(String[] a) throws Exception {
        File dir = new File(a[0]);
        dir.mkdirs();

        System.out.println("[1] MP3 没有 ID3 标签 —— 头部就够");
        File plain = mkMp3(dir, "plain.mp3");
        ok("tagFitsCopy = true", TagIO.tagFitsCopy(plain, ".mp3"));

        System.out.println("[2] MP3 写好 ID3 —— 完整文件判定为够");
        File mp3 = mkMp3(dir, "tag.mp3");
        Map<String, String> values = new HashMap<String, String>();
        values.put("title", "头部测试");
        values.put("artist", "测试歌手");
        Id3.rewrite(mp3, values);
        ok("tagFitsCopy = true", TagIO.tagFitsCopy(mp3, ".mp3"));
        ok("ID3 能读回 title", "头部测试".equals(Id3.read(mp3).get("title")));

        System.out.println("[3] MP3 头部被截断在标签中间 —— 必须判为不够（回退整文件）");
        long tagLen = mp3.length();
        // 截到 ID3 头之后、标签区中间（10 字节头 + 一半标签）
        File cut = head(mp3, dir, "cut.mp3", (int) Math.max(12, 10 + (tagLen - 4096) / 2));
        ok("tagFitsCopy = false", !TagIO.tagFitsCopy(cut, ".mp3"));

        System.out.println("[4] FLAC 有 Vorbis Comment —— 判定为够");
        File flac = new File(dir, "t.flac");
        FileOutputStream fo = new FileOutputStream(flac);
        fo.write(new byte[]{'f', 'L', 'a', 'C'});
        fo.write(0x80);
        fo.write(0);
        fo.write(0);
        fo.write(34);              // STREAMINFO, last=true
        fo.write(new byte[34]);
        for (int i = 0; i < 8192; i++) {
            fo.write(0x11);
        }
        fo.close();
        Map<String, String> fv = new HashMap<String, String>();
        fv.put("title", "FLAC 标题");
        Flac.rewrite(flac, fv);
        ok("tagFitsCopy = true", TagIO.tagFitsCopy(flac, ".flac"));
        ok("FLAC tagFitsCopy 不影响读取", "FLAC 标题".equals(Flac.read(flac).get("title")));

        System.out.println("[5] FLAC 只留 6 字节 —— 元数据块头都没读全，判为不够");
        File flacCut = head(flac, dir, "cut.flac", 6);
        ok("tagFitsCopy = false", !TagIO.tagFitsCopy(flacCut, ".flac"));

        System.out.println("[6] M4A/MP4 —— moov 可能在尾部，一律判为不够");
        ok("tagFitsCopy(.m4a) = false", !TagIO.tagFitsCopy(plain, ".m4a"));

        System.out.println("[7] encoding=0 却存 GBK 的中文标签 —— 兜底解码");
        byte[] gbk = "谢霆锋".getBytes("GBK");
        ok("GBK 中文按 GBK 解出", "谢霆锋".equals(Id3.decodeLatin1OrGbk(gbk)));
        ok("纯 ASCII 原样返回", "Hello".equals(
                Id3.decodeLatin1OrGbk("Hello".getBytes("ISO-8859-1"))));
        ok("Latin-1 重音不被误转", "café".equals(
                Id3.decodeLatin1OrGbk("café".getBytes("ISO-8859-1"))));
        ok("GBK 歌手名", "黄征".equals(
                Id3.decodeLatin1OrGbk("黄征".getBytes("GBK"))));

        System.out.println(fails == 0 ? "\n全部通过 ✅" : "\n失败 " + fails + " 项 ❌");
        if (fails != 0) {
            System.exit(1);
        }
    }
}
