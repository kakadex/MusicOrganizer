package com.dsh.musicorganizer.ui;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Build;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.PrintWriter;
import java.io.StringWriter;

/**
 * 把崩溃信息以纯代码方式渲染到屏幕上（不依赖任何 XML 布局 / 主题资源），
 * 这样即使主题或资源本身有问题也能稳定显示，方便用户截图回传。
 */
public final class CrashScreen {

    public static void show(Activity activity, Throwable t) {
        StringWriter sw = new StringWriter();
        PrintWriter pw = new PrintWriter(sw);
        t.printStackTrace(pw);
        pw.flush();

        StringBuilder sb = new StringBuilder();
        sb.append("启动失败，请截图发给开发者。\n\n");
        try {
            sb.append("版本: ").append(activity.getPackageManager()
                    .getPackageInfo(activity.getPackageName(), 0).versionName).append("\n");
        } catch (Throwable ignore) {
        }
        try {
            sb.append("设备: ").append(Build.MANUFACTURER).append(" ")
              .append(Build.MODEL).append("  Android ")
              .append(Build.VERSION.RELEASE).append("\n");
        } catch (Throwable ignore) {
        }
        sb.append("错误类型: ").append(t.getClass().getName()).append("\n");
        sb.append("错误信息: ").append(String.valueOf(t.getMessage()))
          .append("\n\n");
        sb.append("堆栈跟踪:\n").append(sw.toString());

        ScrollView sv = new ScrollView(activity);
        sv.setBackgroundColor(UiKit.cardColor());
        TextView tv = new TextView(activity);
        tv.setTextColor(Color.parseColor("#D93025"));
        tv.setTypeface(Typeface.MONOSPACE);
        tv.setTextSize(12);
        try {
            int pad = (int) (16 * activity.getResources()
                    .getDisplayMetrics().density);
            tv.setPadding(pad, pad, pad, pad);
        } catch (Throwable ignore) {
            tv.setPadding(32, 32, 32, 32);
        }
        tv.setText(sb.toString());
        activity.setContentView(sv);
    }
}
