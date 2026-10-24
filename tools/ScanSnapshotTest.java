import com.dsh.musicorganizer.core.ScanSnapshot;
import com.dsh.musicorganizer.core.ScanStats;
import com.dsh.musicorganizer.core.TrackGroup;
import com.dsh.musicorganizer.core.VFile;

import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * 扫描结果快照回归（纯 JVM，写到临时目录）。
 *
 * <p>为什么这块必须有测试：它决定「闪退 / 被杀之后文件列表还在不在」，
 * 一旦序列化写歪（字段名改了、下标错位），用户看到的就是「扫描完 0 个文件」，
 * 而且不报错 —— 只能靠往返比对抓出来。
 */
public final class ScanSnapshotTest {

    private static int passed = 0;
    private static int failed = 0;

    private static final String TREE = "content://com.android.externalstorage.documents/tree/primary%3AMusic";

    public static void main(String[] args) throws Exception {
        File dir = new File(args.length > 0 ? args[0] : "snapshot-test");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        ScanSnapshot.clear(dir);

        roundTrip(dir);
        metaRoundTrip(dir);
        legacyVersion(dir);
        treeMismatch(dir);
        corrupt(dir);
        missing(dir);
        compactness(dir);
        clears(dir);

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void roundTrip(File dir) {
        section("存 → 取 往返");
        VFile root = dirFile("primary:Music", "Music");
        List<VFile> files = new ArrayList<VFile>();
        files.add(audio("primary:Music/晴天.mp3", "primary:Music", "晴天.mp3", 4_000_000L));
        files.add(audio("primary:Music/晴天.lrc", "primary:Music", "晴天.lrc", 2_000L));
        files.add(audio("primary:Music/周杰伦/七里香.flac", "primary:Music/周杰伦",
                "七里香.flac", 30_000_000L));

        TrackGroup g1 = new TrackGroup(root, "晴天");
        g1.audio.add(files.get(0));
        g1.lyrics.add(files.get(1));

        VFile artistDir = dirFile("primary:Music/周杰伦", "周杰伦");
        TrackGroup g2 = new TrackGroup(artistDir, "七里香");
        g2.audio.add(files.get(2));

        List<TrackGroup> groups = new ArrayList<TrackGroup>();
        groups.add(g1);
        groups.add(g2);

        ScanStats stats = new ScanStats();
        stats.files = 2;
        stats.groups = 2;
        stats.skippedArtist = 3;
        stats.skippedUnrecognized = 1;
        stats.ignored = 5;

        File saved = ScanSnapshot.save(dir, TREE, root, files, groups, stats);
        check("写盘成功", saved != null && saved.exists());
        check("文件名按 treeUri 散列", saved.getName().startsWith("scan-")
                && saved.getName().endsWith(".json"));
        check("没有残留 .tmp", new File(saved.getPath() + ".tmp").exists() == false);

        ScanSnapshot snap = ScanSnapshot.load(dir, TREE);
        check("能读回来", snap != null);
        if (snap == null) {
            return;
        }
        check("文件数一致", snap.files.size() == 3);
        check("文件名对得上", snap.files.get(2).name.equals("七里香.flac"));
        check("parentId 对得上", "primary:Music/周杰伦".equals(snap.files.get(2).parentId));
        check("大小对得上", snap.files.get(2).size == 30_000_000L);
        check("分组数一致", snap.groups.size() == 2);
        check("第 1 组有音频", snap.groups.get(0).audio.size() == 1);
        check("第 1 组有歌词", snap.groups.get(0).lyrics.size() == 1);
        check("第 1 组基名", "晴天".equals(snap.groups.get(0).basename));
        check("第 1 组目录名", "Music".equals(snap.groups.get(0).dir.name));
        check("第 2 组目录名", "周杰伦".equals(snap.groups.get(1).dir.name));
        check("第 2 组音频是同一对象", snap.groups.get(1).audio.get(0)
                == snap.files.get(2));
        check("统计数字保留", snap.stats.files == 2 && snap.stats.groups == 2
                && snap.stats.skippedArtist == 3 && snap.stats.skippedUnrecognized == 1
                && snap.stats.ignored == 5);
        check("统计摘要可读", snap.stats.summary().contains("共 2 个文件"));
        check("time 有效", snap.savedAt > 0);
        check("ageText 不为空", snap.ageText().length() > 0);
        check("目录不空", !snap.isEmpty());
    }

    /**
     * v2：标签缓存往返。
     *
     * <p>这是「重启后不必重读整库」的地基：如果标签没被写进快照，恢复出来的列表
     * 会把所有行退回「未读标签」，用户又要等一轮全量读取。
     */
    private static void metaRoundTrip(File dir) {
        section("标签缓存往返（v2）");
        VFile root = dirFile("primary:Music", "Music");
        List<VFile> files = new ArrayList<VFile>();

        VFile tagged = audio("primary:Music/晴天.mp3", "primary:Music", "晴天.mp3", 4_000_000L);
        com.dsh.musicorganizer.core.Tags tags = new com.dsh.musicorganizer.core.Tags();
        tags.put("title", "晴天");
        tags.put("artist", "周杰伦");
        tags.put("album", "叶惠美");
        tags.put("year", "2003");
        tagged.cacheMeta(tags, true, true);
        files.add(tagged);

        // 关键：无标签的文件也要缓存「读过且为空」，否则每次都被当成没读过重读
        VFile untagged = audio("primary:Music/未命名.mp3", "primary:Music", "未命名.mp3", 100L);
        untagged.cacheMeta(new com.dsh.musicorganizer.core.Tags(), false, false);
        files.add(untagged);

        // 没读过的文件：不能凭空变成「已读」
        VFile unknown = audio("primary:Music/新建.mp3", "primary:Music", "新建.mp3", 200L);
        files.add(unknown);

        TrackGroup g = new TrackGroup(root, "晴天");
        g.audio.add(tagged);
        List<TrackGroup> groups = new ArrayList<TrackGroup>();
        groups.add(g);

        File saved = ScanSnapshot.save(dir, TREE, root, files, groups, new ScanStats());
        check("写盘成功", saved != null);
        ScanSnapshot snap = ScanSnapshot.load(dir, TREE);
        check("能读回来", snap != null);
        if (snap == null) {
            return;
        }
        check("文件数一致", snap.files.size() == 3);

        VFile r1 = snap.files.get(0);
        check("标签已缓存", r1.metaCached());
        check("标题还原", "晴天".equals(r1.cachedTags.get("title")));
        check("艺人还原", "周杰伦".equals(r1.cachedTags.get("artist")));
        check("专辑还原", "叶惠美".equals(r1.cachedTags.get("album")));
        check("年份还原", "2003".equals(r1.cachedTags.get("year")));
        check("封面标志还原", r1.cachedHasCover);
        check("歌词标志还原", r1.cachedHasLyrics);

        VFile r2 = snap.files.get(1);
        check("无标签文件仍算已读", r2.metaCached());
        check("无标签内容为空", r2.cachedTags.get("title").isEmpty()
                && r2.cachedTags.get("artist").isEmpty());
        check("无标签无封面", !r2.cachedHasCover);

        check("没读过的仍是未读", !snap.files.get(2).metaCached());
    }

    /**
     * 老快照（v1，没有标签缓存）必须还能读 —— 升级之后列表不能凭空消失。
     */
    private static void legacyVersion(File dir) {
        section("v1 老快照兼容");
        String json = "{\"v\":1,\"tree\":\"" + TREE + "\",\"at\":1700000000000,"
                + "\"root\":{\"id\":\"primary:Music\",\"n\":\"Music\"},"
                + "\"stats\":{\"files\":1,\"groups\":0,\"sa\":0,\"su\":0,\"ig\":0,\"au\":0,\"ly\":0},"
                + "\"files\":[{\"id\":\"primary:Music/a.mp3\",\"pid\":\"primary:Music\","
                + "\"n\":\"a.mp3\",\"m\":\"audio/mpeg\",\"s\":100,\"t\":5,\"d\":0}],"
                + "\"groups\":[]}";
        File f = ScanSnapshot.fileOf(dir, TREE);
        try {
            write(f, json);
        } catch (Exception e) {
            check("写入 v1 样本", false);
            return;
        }
        ScanSnapshot snap = ScanSnapshot.load(dir, TREE);
        check("v1 能读回来", snap != null);
        if (snap == null) {
            return;
        }
        check("文件列表保留", snap.files.size() == 1);
        check("文件名正确", "a.mp3".equals(snap.files.get(0).name));
        check("没有标签缓存（按需再读）", !snap.files.get(0).metaCached());
    }

    private static void treeMismatch(File dir) {
        section("换目录不串数据");
        ScanSnapshot snap = ScanSnapshot.load(dir,
                "content://com.android.externalstorage.documents/tree/primary%3ADownload");
        check("别的目录读不到快照", snap == null);
    }

    private static void corrupt(File dir) throws Exception {
        section("坏文件容错");
        File f = ScanSnapshot.fileOf(dir, TREE);
        String good = readAll(f);
        write(f, "{这不是 JSON");
        check("坏 JSON 返回 null", ScanSnapshot.load(dir, TREE) == null);
        write(f, "{\"v\":999,\"tree\":\"" + TREE + "\"}");
        check("版本不符返回 null", ScanSnapshot.load(dir, TREE) == null);
        write(f, good);
        check("恢复后仍可读", ScanSnapshot.load(dir, TREE) != null);
    }

    private static void missing(File dir) {
        section("没有快照");
        check("空目录返回 null",
                ScanSnapshot.load(new File(dir, "not-exists"), TREE) == null);
        check("treeUri 为空返回 null", ScanSnapshot.load(dir, "") == null);
    }

    private static void compactness(File dir) {
        section("体积与去重");
        VFile root = dirFile("primary:Music", "Music");
        List<VFile> files = new ArrayList<VFile>();
        for (int i = 0; i < 500; i++) {
            files.add(audio("primary:Music/song" + i + ".mp3", "primary:Music",
                    "song" + i + ".mp3", 3_000_000L + i));
        }
        TrackGroup g = new TrackGroup(root, "song0");
        g.audio.add(files.get(0));
        List<TrackGroup> groups = new ArrayList<TrackGroup>();
        groups.add(g);
        ScanStats stats = new ScanStats();
        stats.files = 500;
        File saved = ScanSnapshot.save(dir, TREE, root, files, groups, stats);
        check("写盘成功", saved != null);
        // 500 首大约 60KB，2 万首才 ~2.4MB；超过 200KB 说明格式膨胀了
        check("500 首体积 < 200KB", saved.length() < 200 * 1024);
        ScanSnapshot snap = ScanSnapshot.load(dir, TREE);
        check("读回 500 首", snap != null && snap.files.size() == 500);
    }

    private static void clears(File dir) {
        section("清理");
        check("清理前目录里有文件", dir.listFiles() != null && dir.listFiles().length > 0);
        ScanSnapshot.clear(dir);
        File[] left = dir.listFiles();
        check("清理后为空", left == null || left.length == 0);
        check("清理后读不到", ScanSnapshot.load(dir, TREE) == null);
    }

    // ------------------------------------------------------------------

    private static VFile audio(String docId, String parentId, String name, long size) {
        String mime = name.endsWith(".lrc") ? "text/plain" : "audio/mpeg";
        return new VFile(docId, parentId, name, mime, size, 1_700_000_000_000L, false);
    }

    private static VFile dirFile(String docId, String name) {
        return new VFile(docId, null, name, "vnd.android.document/directory", 0, 0, true);
    }

    private static String readAll(File f) throws Exception {
        byte[] b = new byte[(int) f.length()];
        java.io.FileInputStream in = new java.io.FileInputStream(f);
        try {
            int off = 0;
            while (off < b.length) {
                int n = in.read(b, off, b.length - off);
                if (n <= 0) {
                    break;
                }
                off += n;
            }
        } finally {
            in.close();
        }
        return new String(b, "UTF-8");
    }

    private static void write(File f, String text) throws Exception {
        FileOutputStream out = new FileOutputStream(f);
        try {
            out.write(text.getBytes("UTF-8"));
        } finally {
            out.close();
        }
    }

    private static void section(String name) {
        System.out.println();
        System.out.println("[" + name + "]");
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("  ok   " + name);
        } else {
            failed++;
            System.out.println("  FAIL " + name);
        }
    }
}
