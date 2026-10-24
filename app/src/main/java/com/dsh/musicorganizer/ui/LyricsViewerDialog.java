package com.dsh.musicorganizer.ui;

import android.app.Dialog;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.Lyrics;
import com.dsh.musicorganizer.core.LyricsDoc;
import com.dsh.musicorganizer.core.LyricsTimeline;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;

/**
 * 歌词查看器（v0.1.37）—— 把已经解析出来的逐字时间真正显示出来。
 *
 * <p>以前歌词只有「有没有、几行」两个信息，逐字时间（增强型 LRC 的 {@code <mm:ss.xx>}）
 * 解析完就躺在 {@link LyricsDoc.Line#words} 里没人用。这里给它一个界面：
 *
 * <ul>
 *   <li>逐行列出，左侧时间列，当前行高亮；</li>
 *   <li>底部「开始 / 暂停 / 复位」：以歌词时间为轴自动滚动（没有音源也能对时间轴）；</li>
 *   <li>有逐字时间的行显示「逐字」徽标，当前行按逐字进度算百分比。</li>
 * </ul>
 *
 * <p>只是查看与对轴，不改文件；要改时间轴用「歌词偏移」。
 */
public final class LyricsViewerDialog {

    private LyricsViewerDialog() {
    }

    /** 计时刷新间隔（毫秒）：200ms 足够跟手，也不至于让列表一直重绘。 */
    private static final int TICK_MS = 200;

    public static void show(final MainActivity host, final VFile audio) {
        if (audio == null) {
            host.toast("没有选中文件");
            return;
        }
        final Context ctx = host;
        final Dialog dialog = new Dialog(ctx);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);

        LinearLayout root = UiKit.vertical(ctx);
        root.setBackgroundColor(UiKit.bgColor());
        int pad = UiKit.dp(ctx, 16);
        root.setPadding(pad, pad, pad, pad);

        root.addView(UiKit.text(ctx, "歌词时间轴", 18, UiKit.textColor(), true));
        final TextView sub = UiKit.caption(ctx, audio.name);
        UiKit.margin(sub, 0, 4, 0, 6);
        root.addView(sub);

        final TextView status = UiKit.caption(ctx, "正在读歌词…");
        UiKit.margin(status, 0, 0, 0, 6);
        root.addView(status);

        final LineAdapter adapter = new LineAdapter(ctx);
        final ListView list = new ListView(ctx);
        list.setDivider(null);
        list.setDividerHeight(UiKit.dp(ctx, 2));
        list.setVerticalScrollBarEnabled(false);
        list.setAdapter(adapter);
        root.addView(list, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        LinearLayout row = UiKit.horizontal(ctx);
        final Button play = UiKit.button(ctx, "开始", true);
        final Button reset = UiKit.button(ctx, "复位", false);
        final Button close = UiKit.button(ctx, "关闭", false);
        row.addView(play, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        LinearLayout.LayoutParams lp2 = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        lp2.setMargins(UiKit.dp(ctx, 8), 0, 0, 0);
        row.addView(reset, lp2);
        LinearLayout.LayoutParams lp3 = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        lp3.setMargins(UiKit.dp(ctx, 8), 0, 0, 0);
        row.addView(close, lp3);
        UiKit.margin(row, 0, 8, 0, 0);
        root.addView(row);

        adapter.onCurrent = new Runnable() {
            @Override
            public void run() {
                if (adapter.current() >= 0) {
                    list.smoothScrollToPosition(adapter.current());
                }
            }
        };
        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        }
        dialog.show();

        // 计时：以「开始」那一刻为零点
        final Handler handler = new Handler(Looper.getMainLooper());
        final boolean[] playing = new boolean[]{false};
        final long[] base = new long[]{0};
        final Runnable tick = new Runnable() {
            @Override
            public void run() {
                if (!playing[0]) {
                    return;
                }
                long ms = SystemClock.elapsedRealtime() - base[0];
                long last = LyricsTimeline.lastTime(adapter.lines);
                status.setText(LyricsTimeline.statusText(adapter.lines, ms));
                adapter.setPosition(ms);
                if (last >= 0 && ms > last + 3000) {
                    playing[0] = false;
                    play.setText("重播");
                    return;
                }
                handler.postDelayed(this, TICK_MS);
            }
        };

        play.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (adapter.lines.isEmpty()) {
                    host.toast("这首歌没有可用的时间轴歌词");
                    return;
                }
                playing[0] = !playing[0];
                if (playing[0]) {
                    base[0] = SystemClock.elapsedRealtime();
                    play.setText("暂停");
                    handler.post(tick);
                } else {
                    play.setText("继续");
                }
            }
        });
        reset.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                playing[0] = false;
                adapter.setPosition(0);
                status.setText(LyricsTimeline.statusText(adapter.lines, 0));
                play.setText("开始");
            }
        });
        close.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                playing[0] = false;
                handler.removeCallbacksAndMessages(null);
                dialog.dismiss();
            }
        });

        // 后台读歌词（.lrc 优先，其次内嵌）
        new Thread(new Runnable() {
            @Override
            public void run() {
                final String content;
                final String source;
                try {
                    Storage st = host.safeStorage();
                    String text = "";
                    String from = "";
                    VFile lrc = Lyrics.findLrc(st, audio);
                    if (lrc != null) {
                        text = Lyrics.readLrc(st, lrc);
                        from = ".lrc 文件";
                    }
                    if (text.trim().isEmpty()) {
                        Tags t = Scanner.readTagsCheap(st, host.getContentResolver(), audio);
                        text = t.get(Tags.LYRICS);
                        from = "内嵌标签";
                    }
                    content = text == null ? "" : text;
                    source = from;
                } catch (Exception e) {
                    host.runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            status.setText("读歌词失败：" + e.getMessage());
                        }
                    });
                    return;
                }
                host.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        List<LyricsDoc.Line> lines = LyricsTimeline.sortedCopy(
                                LyricsDoc.parse(content));
                        if (lines.isEmpty()) {
                            status.setText(content.trim().isEmpty()
                                    ? "这首歌没有歌词（.lrc 与内嵌都为空）"
                                    : "歌词没有时间轴（" + content.split("\n").length + " 行纯文本）");
                            return;
                        }
                        adapter.setLines(lines);
                        int enhanced = LyricsTimeline.enhancedLineCount(lines);
                        status.setText(lines.size() + " 行 · 来源 " + source
                                + (enhanced > 0 ? " · 其中 " + enhanced + " 行带逐字时间"
                                : " · 无逐字时间"));
                    }
                });
            }
        }).start();
    }

    /** 行列表：当前行高亮 + 自动滚到可见处。 */
    private static final class LineAdapter extends BaseAdapter {
        private final Context ctx;
        final List<LyricsDoc.Line> lines = new ArrayList<LyricsDoc.Line>();
        private long position;
        private int current = -1;
        /** 当前行变化时滚到可见处（由界面层注入，纯计算类里不引 View）。 */
        Runnable onCurrent;

        LineAdapter(Context ctx) {
            this.ctx = ctx;
        }

        void setLines(List<LyricsDoc.Line> value) {
            lines.clear();
            if (value != null) {
                lines.addAll(value);
            }
            notifyDataSetChanged();
        }

        int current() {
            return current;
        }

        void setPosition(long ms) {
            position = ms;
            int idx = LyricsTimeline.lineIndexAt(lines, ms);
            if (idx != current) {
                current = idx;
                notifyDataSetChanged();
                if (onCurrent != null) {
                    onCurrent.run();
                }
            } else {
                // 同行内逐字进度也要刷新百分比
                notifyDataSetChanged();
            }
        }

        @Override
        public int getCount() {
            return lines.size();
        }

        @Override
        public Object getItem(int position) {
            return lines.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int index, View convertView, ViewGroup parent) {
            LinearLayout box = UiKit.horizontal(ctx);
            int pad = UiKit.dp(ctx, 6);
            box.setPadding(pad, pad, pad, pad);
            LyricsDoc.Line line = lines.get(index);
            boolean active = index == current;
            if (active) {
                box.setBackgroundColor(UiKit.primarySoft());
            }
            TextView time = UiKit.text(ctx, LyricsTimeline.stamp(line.timeMs), 12,
                    active ? UiKit.primary() : UiKit.subColor(), active);
            time.setMinWidth(UiKit.dp(ctx, 44));
            box.addView(time);
            String text = line.text.isEmpty() ? "♪" : line.text;
            TextView body = UiKit.text(ctx, text, active ? 16 : 14,
                    active ? UiKit.primary() : UiKit.bodyColor(), active);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            lp.setMargins(UiKit.dp(ctx, 8), 0, 0, 0);
            box.addView(body, lp);
            if (line.words != null && !line.words.isEmpty()) {
                box.addView(UiKit.badge(ctx, "逐字", UiKit.accentColor()));
            }
            if (active && !line.words.isEmpty()) {
                int next = index + 1 < lines.size() ? (int) lines.get(index + 1).timeMs
                        : (int) line.timeMs + 5000;
                double p = LyricsTimeline.progressAt(line, position, next);
                TextView pc = UiKit.text(ctx, Math.round(p * 100) + "%", 11,
                        UiKit.subColor(), false);
                box.addView(pc);
            }
            return box;
        }
    }
}
