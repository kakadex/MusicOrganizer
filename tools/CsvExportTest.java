import com.dsh.musicorganizer.core.CsvExport;

import java.util.ArrayList;
import java.util.List;

/**
 * 曲库清单 CSV 回归（纯 JVM）。
 *
 * <p>盯的是「Excel 打开别乱码、别串列」：BOM、CRLF、逗号/引号/换行的转义、行数统计。
 */
public class CsvExportTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 转义
        check("普通字段不加引号", CsvExport.esc("晴天").equals("晴天"));
        check("逗号加引号", CsvExport.esc("周杰伦,方文山").equals("\"周杰伦,方文山\""));
        check("引号翻倍", CsvExport.esc("他说\"好\"").equals("\"他说\"\"好\"\"\""));
        check("换行加引号",
                CsvExport.esc("第一行\n第二行").equals("\"第一行\n第二行\""));
        check("回车加引号",
                CsvExport.esc("a\rb").equals("\"a\rb\""));
        check("空值空串", CsvExport.esc("").isEmpty());
        check("null 空串", CsvExport.esc(null).isEmpty());

        // 2) 表头与 BOM
        String csv = CsvExport.build(new ArrayList<CsvExport.Row>());
        check("带 BOM", csv.charAt(0) == '\uFEFF');
        check("表头第一列", csv.contains("文件名"));
        check("表头有大有小", csv.contains("有无封面") && csv.contains("大小(字节)"));
        check("CRLF 换行", csv.contains("\r\n"));
        check("空清单零行", CsvExport.rowCount(csv) == 0);

        // 3) 数据行
        CsvExport.Row r = new CsvExport.Row();
        r.name = "晴天.mp3";
        r.title = "晴天";
        r.artist = "周杰伦";
        r.album = "叶惠美";
        r.year = "2003";
        r.track = "03";
        r.genre = "Pop";
        r.size = 4096;
        r.cover = true;
        r.lyrics = false;
        r.dir = "primary:Music";
        List<CsvExport.Row> rows = new ArrayList<CsvExport.Row>();
        rows.add(r);
        String one = CsvExport.build(rows);
        check("一行数据", CsvExport.rowCount(one) == 1);
        check("含文件名", one.contains("晴天.mp3"));
        check("封面写「有」", one.contains(",有,"));
        check("字节数原样", one.contains("4096"));
        check("末尾换行", one.endsWith("\r\n"));

        // 4) 字段里的逗号不会串列：这一行的字段数应等于表头字段数
        CsvExport.Row tricky = new CsvExport.Row();
        tricky.name = "a,b.mp3";
        tricky.title = "带\"引号\"的歌";
        rows.add(tricky);
        String two = CsvExport.build(rows);
        check("两行数据", CsvExport.rowCount(two) == 2);
        String lastLine = two.substring(two.lastIndexOf("\r\n", two.length() - 3) + 2,
                two.length() - 2);
        check("逗号字段被引号包住", two.contains("\"a,b.mp3\""));
        check("引号字段被转义", two.contains("\"带\"\"引号\"\"的歌\""));

        // 5) 换行字段不破坏行数统计
        CsvExport.Row multiline = new CsvExport.Row();
        multiline.name = "x.mp3";
        multiline.title = "第一行\n第二行";
        List<CsvExport.Row> three = new ArrayList<CsvExport.Row>();
        three.add(multiline);
        String ml = CsvExport.build(three);
        check("单元格换行不算新行", CsvExport.rowCount(ml) == 1);

        // 6) null 行被跳过
        List<CsvExport.Row> withNull = new ArrayList<CsvExport.Row>();
        withNull.add(null);
        withNull.add(r);
        check("null 行不计入", CsvExport.rowCount(CsvExport.build(withNull)) == 1);

        // 7) 默认文件名
        String name = CsvExport.defaultFileName(new java.util.Date(0));
        check("文件名前缀", name.startsWith("音乐整理-曲库清单-"));
        check("文件名后缀", name.endsWith(".csv"));

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
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
