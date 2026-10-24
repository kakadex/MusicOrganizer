import com.dsh.musicorganizer.core.Junk;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;

/**
 * 垃圾文件识别回归（纯 JVM）。
 *
 * <p>盯的是「别把正常文件当垃圾」：正常音频/歌词、目录、隐藏的未知文件都不能进清单；
 * 0 字节、.lrc.bak、临时文件、系统垃圾必须被认出来。
 */
public class JunkTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 不该被判为垃圾的
        check("正常 mp3", Junk.reasonOf(file("晴天.mp3", 4 * 1024 * 1024)) == null);
        check("正常 flac", Junk.reasonOf(file("叶惠美.flac", 30 * 1024 * 1024)) == null);
        check("正常 lrc", Junk.reasonOf(file("晴天.lrc", 2048)) == null);
        check("目录不算", Junk.reasonOf(dir("周杰伦")) == null);
        check("未知扩展名不算", Junk.reasonOf(file("cover.jpg", 1024)) == null);
        check("隐藏未知文件不算", Junk.reasonOf(file(".nomedia", 0)) == null);
        check("空名也算垃圾", Junk.reasonOf(file("   ", 10)) != null);

        // 2) 该报出来的
        check("0 字节 mp3", part(Junk.reasonOf(file("坏文件.mp3", 0))).contains("0 字节"));
        check("0 字节 lrc", Junk.reasonOf(file("空.lrc", 0)) != null);
        check(".lrc.bak", Junk.reasonOf(file("晴天.lrc.bak", 3000)) != null
                && Junk.reasonOf(file("晴天.lrc.bak", 3000)).contains("歌词备份"));
        check(".tmp", Junk.reasonOf(file("x.tmp", 100)) != null);
        check(".part", Junk.reasonOf(file("x.part", 100)) != null);
        check(".crdownload", Junk.reasonOf(file("x.crdownload", 100)) != null);
        check("Thumbs.db", Junk.reasonOf(file("Thumbs.db", 4096)) != null);
        check("大小写不敏感", Junk.reasonOf(file("thumbs.DB", 4096)) != null);
        check(".DS_Store", Junk.reasonOf(file(".DS_Store", 6148)) != null);
        check("desktop.ini", Junk.reasonOf(file("desktop.ini", 200)) != null);
        check("小音频", Junk.reasonOf(file("tiny.mp3", 512)) != null
                && Junk.reasonOf(file("tiny.mp3", 512)).contains("1KB"));

        // 3) 清单与统计
        List<VFile> files = new ArrayList<VFile>();
        files.add(file("晴天.mp3", 4 * 1024 * 1024));
        files.add(file("晴天.lrc.bak", 1000));
        files.add(file("x.tmp", 500));
        files.add(file("空.mp3", 0));
        files.add(dir("周杰伦"));
        List<Junk.Item> items = Junk.plan(files);
        check("挑出 3 个", items.size() == 3);
        check("保持原顺序", items.get(0).file.name.equals("晴天.lrc.bak"));
        check("总字节", Junk.totalSize(items) == 1500);
        check("摘要含可释放", Junk.summary(items).contains("可释放"));
        check("空摘要", Junk.summary(new ArrayList<Junk.Item>()).contains("没有"));

        // 4) 按原因分组
        check("分组三类", Junk.byReason(items).size() == 3);
        check("null 安全", Junk.plan(null).isEmpty());
        check("null 原因安全", Junk.reasonOf(null) == null);

        // 5) 回归：清理必须基于「全部文件」，不能只喂音乐文件。
        //    旧实现 Junk.plan(repo.lastFiles) 的 lastFiles 来自 walkMusic（只收 music()），
        //    于是 .lrc.bak / .tmp / Thumbs.db 永远进不来 —— 歌词备份清不掉就是这个根因。
        //    这里用真实样本文件名固化契约：全量数据能扫到，音乐-only 数据扫不到。
        {
            // 一个子目录下的真实曲库片段：音频 + 同名歌词
            List<VFile> musicOnly = new ArrayList<VFile>();
            musicOnly.add(file("示例歌手-示例曲目.mp3", 4_000_000));
            musicOnly.add(file("示例歌手-示例曲目.lrc", 2000));
            // 旧数据源（walkMusic 产出）里根本没有 .lrc.bak，于是 plan 返回空 —— 这就是 bug 表现
            check("旧数据源(仅音乐)扫不到任何垃圾", Junk.plan(musicOnly).isEmpty());

            // 新数据源（Scanner.walkAll 产出）包含非音乐文件
            List<VFile> allFiles = new ArrayList<VFile>(musicOnly);
            allFiles.add(file("示例歌手-示例曲目.lrc.bak", 3000));
            allFiles.add(file("Thumbs.db", 4096));
            List<Junk.Item> fixed = Junk.plan(allFiles);
            check("新数据源扫到 2 个垃圾", fixed.size() == 2);
            boolean sawBak = false;
            boolean sawThumb = false;
            for (Junk.Item it : fixed) {
                if (it.file.name.endsWith(".lrc.bak") && it.reason.contains("歌词备份")) {
                    sawBak = true;
                }
                if (it.file.name.equalsIgnoreCase("Thumbs.db")) {
                    sawThumb = true;
                }
            }
            check("新数据源认出 .lrc.bak 歌词备份", sawBak);
            check("新数据源认出 Thumbs.db 系统垃圾", sawThumb);
        }

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    private static String part(String reason) {
        return reason == null ? "" : reason;
    }

    private static VFile file(String name, long size) {
        return new VFile("primary:Music/" + name, "primary:Music", name, "", size, 0, false);
    }

    private static VFile dir(String name) {
        return new VFile("primary:Music/" + name, "primary:Music", name, "", 0, 0, true);
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
