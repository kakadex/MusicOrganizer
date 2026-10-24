import com.dsh.musicorganizer.core.BatchEdit;

import java.util.Map;

/**
 * 批量编辑回归（纯 JVM）。
 *
 * <p>盯三件事：没勾的字段绝不能出现在写入表里（否则会误清标签）、
 * 音轨号必须按序号递增、空规格不许误触发写盘。
 */
public class BatchEditTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 只写勾选的字段
        BatchEdit.Spec spec = new BatchEdit.Spec();
        spec.values.put("album", "十一月的萧邦");
        spec.values.put("genre", "Pop");
        Map<String, String> u0 = BatchEdit.updatesFor(spec, 0);
        check("只含两个字段", u0.size() == 2);
        check("专辑写入", "十一月的萧邦".equals(u0.get("album")));
        check("流派写入", "Pop".equals(u0.get("genre")));
        check("没有标题字段", u0.get("title") == null);
        check("没开音轨重排", u0.get("track") == null);

        // 2) 音轨重排：从起始值递增
        BatchEdit.Spec t = new BatchEdit.Spec();
        t.renumberTrack = true;
        t.trackStart = 11;
        check("第一首 11", "11".equals(BatchEdit.updatesFor(t, 0).get("track")));
        check("第二首 12", "12".equals(BatchEdit.updatesFor(t, 1).get("track")));
        check("第四首 14", "14".equals(BatchEdit.updatesFor(t, 3).get("track")));

        // 3) 音轨重排与普通字段共存
        t.values.put("album", "DISC 2");
        Map<String, String> u = BatchEdit.updatesFor(t, 2);
        check("共存：专辑+音轨", u.size() == 2 && "13".equals(u.get("track")));

        // 4) 空值表示清除
        BatchEdit.Spec c = new BatchEdit.Spec();
        c.values.put("comment", "");
        check("空值保留为空串（清除语义）", "".equals(BatchEdit.updatesFor(c, 0).get("comment")));

        // 5) 空规格
        check("空规格 isEmpty", new BatchEdit.Spec().isEmpty());
        check("空规格不产生写入", BatchEdit.updatesFor(new BatchEdit.Spec(), 0).isEmpty());
        check("空规格摘要", new BatchEdit.Spec().summary().contains("没有"));

        // 6) 摘要可读
        String s = t.summary();
        check("摘要含专辑", s.contains("DISC 2"));
        check("摘要含音轨起始", s.contains("从 11 开始"));
        check("清除字段摘要可读", c.summary().contains("清空"));

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
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
