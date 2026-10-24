import com.dsh.musicorganizer.core.MediaTrack;

import java.util.ArrayList;
import java.util.List;

/**
 * 系统媒体库条目回归（纯 JVM，v0.1.42）。
 *
 * <p>盯的是「列表显示别错、筛选别漏、导入文件名别非法」。
 */
public class MediaTrackTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        MediaTrack t = new MediaTrack(1, "晴天", "周杰伦", "叶惠美", 269000, 4 * 1024 * 1024,
                "audio/mpeg", "/storage/emulated/0/Download/晴天.mp3");

        // 1) 显示
        check("标题含艺人", t.display().equals("周杰伦 - 晴天"));
        check("文件名取路径末段", t.fileName().equals("晴天.mp3"));
        check("目录取上一层", t.folder.equals("Download"));
        check("详情含大小", t.detail().contains("MB"));
        check("详情含时长", t.detail().contains("4:29"));
        check("详情含专辑", t.detail().contains("叶惠美"));
        check("时长秒", t.durationSeconds() != null
                && Math.abs(t.durationSeconds().doubleValue() - 269.0) < 0.01);

        // 2) 缺字段时的兜底
        MediaTrack bare = new MediaTrack(2, "", "", "", 0, 1024, "audio/flac", "");
        check("无标题用 id 文件名", bare.display().equals("track-2.flac"));
        check("无时长不显示时长", !bare.detail().contains(":"));
        check("无 path 文件名用 id", bare.fileName().equals("track-2.flac"));

        MediaTrack noArtist = new MediaTrack(3, "稻香", "", "", 0, 100, "audio/mpeg", "");
        check("无艺人只显示标题", noArtist.display().equals("稻香"));

        // 3) 筛选
        List<MediaTrack> list = new ArrayList<MediaTrack>();
        list.add(t);
        list.add(new MediaTrack(4, "稻香", "周杰伦", "魔杰座", 0, 100, "audio/mpeg",
                "/storage/emulated/0/Music/稻香.mp3"));
        list.add(new MediaTrack(5, "夜曲", "周杰伦", "十一月的萧邦", 0, 100, "audio/mpeg", ""));
        check("空查询原样返回", MediaTrack.filter(list, "").size() == 3);
        check("空格查询原样返回", MediaTrack.filter(list, "   ").size() == 3);
        check("null 查询原样返回", MediaTrack.filter(list, null).size() == 3);
        check("按歌名筛", MediaTrack.filter(list, "稻香").size() == 1);
        check("按艺人筛", MediaTrack.filter(list, "周杰伦").size() == 3);
        check("多词与", MediaTrack.filter(list, "周杰伦 夜曲").size() == 1);
        check("按目录筛", MediaTrack.filter(list, "Download").size() == 1);
        check("无命中为空", MediaTrack.filter(list, "不存在").isEmpty());
        check("null 列表安全", MediaTrack.filter(null, "x").isEmpty());

        // 4) 排序
        List<MediaTrack> bySize = new ArrayList<MediaTrack>(list);
        MediaTrack.sortBySize(bySize);
        check("体积倒序", bySize.get(0).id == 1);
        List<MediaTrack> byTitle = new ArrayList<MediaTrack>(list);
        MediaTrack.sortByTitle(byTitle);
        check("标题升序首项", byTitle.get(0).display().compareTo(byTitle.get(1).display()) <= 0);

        // 5) 统计
        check("总字节", MediaTrack.totalSize(list) == 4 * 1024 * 1024 + 200);
        check("摘要含首数", MediaTrack.summary(list).contains("3 首"));
        check("空摘要", MediaTrack.summary(new ArrayList<MediaTrack>()).contains("没有"));
        check("null 摘要安全", MediaTrack.summary(null).contains("没有"));

        // 6) 导入文件名
        MediaTrack dirty = new MediaTrack(9, "a/b:c*?", "x", "", 0, 1, "audio/mpeg", "");
        check("非法字符被清", MediaTrack.safeFileName(dirty).indexOf('/') < 0
                && MediaTrack.safeFileName(dirty).indexOf(':') < 0);
        MediaTrack nameless = new MediaTrack(10, "", "", "", 0, 1, "audio/mpeg", "///");
        check("空名兜底", MediaTrack.safeFileName(nameless).startsWith("track-10"));
        MediaTrack longName = new MediaTrack(11, "很长的名字", "", "", 0, 1, "audio/mpeg",
                "/a/" + repeat('长', 120) + ".mp3");
        check("超长截断", MediaTrack.safeFileName(longName).length() <= 90);

        // 7) 目录名
        check("根目录无 folder", MediaTrack.folderOf("/a.mp3").isEmpty());
        check("null 安全", MediaTrack.folderOf(null).isEmpty());

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    private static String repeat(char c, int n) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++) {
            sb.append(c);
        }
        return sb.toString();
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
