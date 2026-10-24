import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.net.Endpoints;
import com.dsh.musicorganizer.net.Sources;

import java.util.List;

/**
 * 联网自检（开发者用，不参与 CI）：直接打各家的真实接口，看能不能拿回候选、字段是否齐全。
 *
 * <p>为什么需要它：接口地址和返回结构随时会变（这次就是 网易 /web 返 405、
 * QQ client_search_cp 返 500、咪咕老接口下线）。改完 Sources 后跑一遍，比在手机上试快得多。
 *
 * <p>用法（需要 JDK 与 org.json）：
 * <pre>
 *   javac -cp json.jar -d out core/{TextUtil,NameWeight,CancelToken}.java \
 *         net/{Http,Endpoints,Sources,MbClient}.java tools/SourceSmokeTest.java
 *   java -cp "out:json.jar" SourceSmokeTest [歌手] [歌名]
 * </pre>
 */
public final class SourceSmokeTest {

    public static void main(String[] args) {
        String artist = args.length > 0 ? args[0] : "周杰伦";
        String title = args.length > 1 ? args[1] : "晴天";

        Sources.Query q = new Sources.Query();
        String[] pair = {artist, title};
        q.filenameCandidates.add(pair);
        q.embeddedTags.put("title", title);
        q.embeddedTags.put("artist", artist);
        q.filenameWeight = NameWeight.fromPercent(NameWeight.DEFAULT_PERCENT);
        q.useCnSources = true;

        System.out.println("查询：" + artist + " - " + title);
        System.out.println();

        probe("网易云", Sources.netease(q));
        probe("QQ 音乐", Sources.qqMusic(q));
        probe("酷狗", Sources.kugou(q));
        probe("酷我", Sources.kuwo(q));
        probe("咪咕", Sources.migu(q));
        probe("Deezer", Sources.deezer(q));
        probe("iTunes", Sources.iTunes(q));
    }

    private static void probe(String label, List<Sources.Candidate> list) {
        if (list == null || list.isEmpty()) {
            System.out.println("✗ " + label + "：0 条"
                    + (com.dsh.musicorganizer.net.Http.lastError() == null ? ""
                    : "（" + com.dsh.musicorganizer.net.Http.lastError() + "）"));
            return;
        }
        System.out.println("✓ " + label + "：" + list.size() + " 条");
        Sources.Candidate c = list.get(0);
        System.out.println("    " + c.title + " / " + c.artist
                + " / " + c.album
                + " / 年份=" + (c.year.isEmpty() ? "-" : c.year)
                + " / 音轨=" + (c.track.isEmpty() ? "-" : c.track)
                + " / 流派=" + (c.genre.isEmpty() ? "-" : c.genre)
                + " / 时长=" + (c.duration == null ? "-" : c.duration.intValue()));
        int withYear = 0;
        int withTrack = 0;
        int withGenre = 0;
        for (Sources.Candidate x : list) {
            if (!x.year.isEmpty()) {
                withYear++;
            }
            if (!x.track.isEmpty()) {
                withTrack++;
            }
            if (!x.genre.isEmpty()) {
                withGenre++;
            }
        }
        System.out.println("    字段覆盖：年份 " + withYear + "/" + list.size()
                + "，音轨 " + withTrack + "/" + list.size()
                + "，流派 " + withGenre + "/" + list.size());
    }
}
