import com.dsh.musicorganizer.core.ArtistRules;
import com.dsh.musicorganizer.core.NameParser;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.net.MbClient;
import com.dsh.musicorganizer.net.Sources;

import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.util.List;

/**
 * 联网探测（开发者用，不参与 CI）：把「识别不出来」的曲名清单丢给八源召回，
 * 看 Organizer.identifyBySources 的校验规则能救回多少。
 *
 * <p>为什么要单独一个工具：Organizer 依赖 android.content.ContentResolver，
 * 桌面 JVM 跑不起来；而召回 + 校验这段是纯逻辑，抽出来就能离线验证。
 *
 * <p>用法（需要 JDK 与 org.json，走代理时加 -Dhttps.proxyHost/-Dhttps.proxyPort）：
 * <pre>
 *   javac -encoding UTF-8 -cp json.jar -d out \
 *     core/{TextUtil,NameParser,ArtistRules,NameWeight,CancelToken,Progress}.java \
 *     net/{Http,Endpoints,Sources,MbClient}.java tools/OrganizeNetProbe.java
 *   java -cp "out:json.jar" OrganizeNetProbe names.txt
 * </pre>
 */
public final class OrganizeNetProbe {

    public static void main(String[] args) throws Exception {
        String path = args.length > 0 ? args[0] : "/tmp/unrec20.txt";
        double threshold = args.length > 1 ? Double.parseDouble(args[1]) : 0.40;
        // 可选：已有歌手目录清单（一行一个），用来模拟「拼音名落回中文目录」
        java.util.Map<String, String> folders = new java.util.LinkedHashMap<String, String>();
        if (args.length > 2) {
            BufferedReader fr = new BufferedReader(new InputStreamReader(
                    new FileInputStream(args[2]), "UTF-8"));
            String f;
            while ((f = fr.readLine()) != null) {
                String name = f.trim();
                if (!name.isEmpty()) {
                    folders.put(folderKey(name), name);
                }
            }
            fr.close();
        }
        MbClient mb = new MbClient();
        BufferedReader br = new BufferedReader(new InputStreamReader(
                new FileInputStream(path), "UTF-8"));
        int ok = 0;
        int miss = 0;
        String line;
        while ((line = br.readLine()) != null) {
            String stem = line.trim();
            if (stem.isEmpty()) {
                continue;
            }
            String picked = null;
            String top = "(无候选)";
            try {
                Sources.Query q = new Sources.Query();
                q.filenameCandidates.addAll(NameParser.candidatePairs(stem));
                q.embeddedTags.put("title", "");
                q.embeddedTags.put("artist", "");
                q.useCnSources = true;
                List<Sources.Candidate> cands = Sources.aggregate(mb, q, null, null);
                String[] pair = q.filenameCandidates.isEmpty()
                        ? new String[]{"", ""} : q.filenameCandidates.get(0);
                String expected = ArtistRules.normalizeCandidate(pair[0]);
                if (ArtistRules.isGenericArtist(expected)) {
                    expected = "";
                }
                double minConf = expected.isEmpty() ? threshold : 0.30;
                if (cands != null && !cands.isEmpty()) {
                    Sources.Candidate c0 = cands.get(0);
                    top = c0.source + " " + String.format("%.2f", c0.confidence)
                            + " " + c0.artist + " - " + c0.title;
                }
                java.util.List<String> acceptable = new java.util.ArrayList<String>();
                if (cands != null) {
                    for (Sources.Candidate c : cands) {
                        if (c.confidence < minConf || acceptable.size() >= 6) {
                            continue;
                        }
                        String title = NameParser.stripNameNoise(c.title == null ? "" : c.title);
                        if (title.isEmpty() || !titleMatches(title, pair[1])) {
                            continue;
                        }
                        String artist = ArtistRules.normalizeCandidate(
                                c.artist == null ? "" : c.artist);
                        if (ArtistRules.isGenericArtist(artist)) {
                            continue;
                        }
                        if (!ArtistRules.isReasonableArtistReturn(artist, title, stem,
                                expected.isEmpty() ? null : expected)) {
                            continue;
                        }
                        acceptable.add(artist);
                    }
                }
                if (!acceptable.isEmpty()) {
                    for (String artist : acceptable) {
                        String canonical = folders.get(folderKey(artist));
                        if (canonical != null) {
                            picked = canonical + "  (复用目录)";
                            break;
                        }
                    }
                    if (picked == null && TextUtil.containsChinese(stem)) {
                        for (String artist : acceptable) {
                            if (TextUtil.containsChinese(artist)) {
                                picked = artist;
                                break;
                            }
                        }
                    }
                    if (picked == null) {
                        picked = acceptable.get(0);
                    }
                }
            } catch (Exception e) {
                top = "异常 " + e;
            }
            if (picked != null) {
                ok++;
                System.out.println("OK   " + stem + " -> " + picked);
            } else {
                miss++;
                System.out.println("MISS " + stem + " | top: " + top);
            }
        }
        br.close();
        System.out.println("---- 召回成功 " + ok + " / 失败 " + miss + " ----");
    }

    private static String folderKey(String s) {
        String n = TextUtil.normCompare(TextUtil.toSimplified(s == null ? "" : s));
        return n.replace("&", "and").replace("、", "and").replace("，", "and")
                .replace(",", "and").replace("+", "and").replace("＆", "and");
    }

    private static boolean titleMatches(String returned, String fromName) {
        String ret = TextUtil.normCompare(returned);
        String exp = TextUtil.normCompare(NameParser.stripNameNoise(fromName == null ? "" : fromName));
        if (exp.isEmpty() || ret.isEmpty()) {
            return false;
        }
        if (exp.equals(ret) || exp.contains(ret) || ret.contains(exp)) {
            return true;
        }
        return TextUtil.ratio(exp, ret) >= 0.72;
    }
}
