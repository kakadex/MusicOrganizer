import com.dsh.musicorganizer.core.ArtistRules;
import com.dsh.musicorganizer.core.NameParser;
import com.dsh.musicorganizer.core.TextUtil;

import java.io.BufferedReader;
import java.io.FileReader;
import java.util.List;

/**
 * 诊断：拿真实文件名跑 Organizer.identifyGroup 的「快模式」路径，
 * 看每一组为什么识别不出来（不联网，纯规则）。
 */
public class OrganizeDiag {
    public static void main(String[] args) throws Exception {
        String path = args.length > 0 ? args[0] : "/tmp/unrec_names.txt";
        BufferedReader br = new BufferedReader(new FileReader(path));
        int ok = 0, fail = 0;
        String line;
        while ((line = br.readLine()) != null) {
            String stem = line.trim();
            if (stem.isEmpty()) continue;
            List<NameParser.Candidate> cands = NameParser.nameCandidates(stem);
            String picked = null;
            String why = "";
            for (NameParser.Candidate c : cands) {
                String a = ArtistRules.normalizeCandidate(c.artist == null ? "" : c.artist);
                String t = NameParser.stripNameNoise(c.title == null ? "" : c.title);
                if (a.isEmpty()) { why = why + "[artist空:" + c.style + "]"; continue; }
                if (t.isEmpty()) { why = why + "[title空:" + c.style + "]"; continue; }
                if (a.equals(t)) { why = why + "[同名:" + c.style + "]"; continue; }
                if (!ArtistRules.isReasonableArtistReturn(a, t, stem, null)) {
                    why = why + "[规则拒:" + c.style + "=" + a + "]";
                    continue;
                }
                picked = a;
                break;
            }
            if (picked != null) {
                ok++;
            } else {
                fail++;
                System.out.println("FAIL\t" + stem + "\t候选数=" + cands.size() + "\t" + why);
            }
        }
        br.close();
        System.out.println("---- 可识别 " + ok + " / 不可识别 " + fail + " ----");
    }
}
