package com.dsh.musicorganizer.ui;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

import com.dsh.musicorganizer.core.CoverArt;
import com.dsh.musicorganizer.core.Lyrics;
import com.dsh.musicorganizer.core.NameParser;
import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.TagIO;
import com.dsh.musicorganizer.core.TagTransaction;
import com.dsh.musicorganizer.core.TagFix;
import com.dsh.musicorganizer.core.MediaRefresh;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.VFile;
import com.dsh.musicorganizer.net.Http;
import com.dsh.musicorganizer.net.Sources;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.io.File;
import java.io.FileOutputStream;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 单文件标签编辑器。
 *
 * <p>分区折叠：封面 / 基本信息 / 歌词 / 在线匹配。改动过的字段右侧亮「● 已改」，点它单项回滚；
 * 底部按钮实时显示「保存（N 项）」。
 *
 * <p>写盘前仍弹「旧值 → 新值」确认框（写入前可反悔）；字段与封面走同一条事务
 * （{@link TagTransaction#applyWithCover}），失败原文件不动。
 */
public final class TagEditorDialog {

    /** 封面选择用；MainActivity.onActivityResult 转给 {@link #handlePickResult}。 */
    public static final int REQ_PICK_COVER = 43;
    private static final int MAX_COVER_BYTES = 8 * 1024 * 1024;

    private interface CoverCallback {
        void onPicked(byte[] bytes);
    }

    private static CoverCallback pendingPick;

    private TagEditorDialog() {
    }

    public static void handlePickResult(Context ctx, int resultCode, Intent data) {
        CoverCallback cb = pendingPick;
        pendingPick = null;
        if (cb == null || resultCode != Activity.RESULT_OK || data == null
                || data.getData() == null) {
            return;
        }
        byte[] bytes = readUri(ctx.getContentResolver(), data.getData());
        if (bytes != null && bytes.length > 0) {
            cb.onPicked(bytes);
        }
    }

    public static void show(final MainActivity host, final VFile file) {
        new Editor(host, file).open();
    }

    // ------------------------------------------------------------------

    private static final class Editor {
        final MainActivity host;
        final VFile file;
        final Context ctx;
        final boolean writable;

        final Map<String, EditText> inputs = new LinkedHashMap<String, EditText>();
        final Map<String, TextView> dots = new LinkedHashMap<String, TextView>();
        final Map<String, String> initial = new LinkedHashMap<String, String>();

        Tags before = new Tags();
        String beforeLyrics = "";
        /** null = 不改；否则为新的歌词正文。 */
        String pendingLyrics;

        /** null = 不动封面；长度 0 = 删除；否则为新图。 */
        byte[] pendingCover;

        /** 本地文件时长（秒）；0 = 未知。用于在候选里显示「本地差 +2s」。 */
        double localDurSec;

        ImageView coverView;
        TextView coverInfo;
        TextView lyricPreview;
        TextView lyricDot;
        TextView status;
        TextView weightValue;
        SeekBar weightBar;
        LinearLayout candidates;
        AlertDialog dialog;
        UiKit.Section coverSection;
        UiKit.Section lyricSection;
        UiKit.Section onlineSection;

        Editor(MainActivity host, VFile file) {
            this.host = host;
            this.file = file;
            this.ctx = host;
            this.writable = TagIO.canWrite(file.ext());
        }

        void open() {
            ScrollView scroll = new ScrollView(ctx);
            LinearLayout box = UiKit.vertical(ctx);
            int pad = UiKit.dp(ctx, 16);
            box.setPadding(pad, pad, pad, pad);

            box.addView(UiKit.text(ctx, file.name, 15, UiKit.textColor(), true));
            status = UiKit.caption(ctx, "正在读取标签…");
            UiKit.margin(status, 0, 4, 0, 8);
            box.addView(status);

            buildCoverSection(box);
            buildBasicSection(box);
            buildLyricSection(box);
            buildOnlineSection(box);

            scroll.addView(box);

            dialog = new UiKit.Builder(ctx)
                    .setTitle("编辑标签")
                    .setView(scroll)
                    .setPositiveButton("保存", null)
                    .setNegativeButton("取消", null)
                    .create();

            dialog.setOnShowListener(new android.content.DialogInterface.OnShowListener() {
                @Override
                public void onShow(android.content.DialogInterface d) {
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                            .setOnClickListener(new View.OnClickListener() {
                                @Override
                                public void onClick(View v) {
                                    save();
                                }
                            });
                    refreshSaveButton();
                }
            });

            loadTags();
            dialog.show();
            UiKit.tintDialog(dialog);
        }

        // --------------------------------------------------------------
        // 封面
        // --------------------------------------------------------------

        private void buildCoverSection(LinearLayout box) {
            box.addView(UiKit.divider(ctx));
            coverSection = UiKit.section(ctx, "封面", true);
            LinearLayout row = UiKit.horizontal(ctx);
            row.setGravity(Gravity.CENTER_VERTICAL);

            coverView = new ImageView(ctx);
            coverView.setLayoutParams(new LinearLayout.LayoutParams(
                    UiKit.dp(ctx, 72), UiKit.dp(ctx, 72)));
            coverView.setScaleType(ImageView.ScaleType.CENTER_CROP);
            row.addView(coverView);

            LinearLayout info = UiKit.vertical(ctx);
            LinearLayout.LayoutParams ipl = new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            ipl.setMargins(UiKit.dp(ctx, 10), 0, 0, 0);
            row.addView(info, ipl);
            coverInfo = UiKit.caption(ctx, "读取中…");
            info.addView(coverInfo);

            LinearLayout btns = UiKit.horizontal(ctx);
            UiKit.margin(btns, 0, 6, 0, 0);
            // 四个动作排成两行（窄屏一行放不下）：在线取 / 本地选 // 移除 / 导出到目录
            LinearLayout btns1 = UiKit.horizontal(ctx);
            UiKit.margin(btns1, 0, 6, 0, 0);
            info.addView(btns1);
            LinearLayout btns2 = UiKit.horizontal(ctx);
            UiKit.margin(btns2, 0, 6, 0, 0);
            info.addView(btns2);

            String[][] rows = {{"在线取封面", "从文件选封面"}, {"移除封面", "导出到目录"}};
            Button[][] coverBtns = new Button[2][2];
            for (int r = 0; r < rows.length; r++) {
                LinearLayout line = r == 0 ? btns1 : btns2;
                for (int i = 0; i < rows[r].length; i++) {
                    Button b = UiKit.button(ctx, rows[r][i], false);
                    b.setTextSize(11f);
                    b.setSingleLine(false);
                    b.setMaxLines(2);
                    b.setGravity(Gravity.CENTER);
                    b.setPadding(UiKit.dp(ctx, 4), UiKit.dp(ctx, 4),
                            UiKit.dp(ctx, 4), UiKit.dp(ctx, 4));
                    LinearLayout.LayoutParams blp =
                            new LinearLayout.LayoutParams(0, UiKit.dp(ctx, 48), 1f);
                    if (i > 0) {
                        blp.setMargins(UiKit.dp(ctx, 6), 0, 0, 0);
                    }
                    line.addView(b, blp);
                    coverBtns[r][i] = b;
                }
            }
            final Button online = coverBtns[0][0];
            final Button pick = coverBtns[0][1];
            final Button remove = coverBtns[1][0];
            final Button export = coverBtns[1][1];

            coverSection.body.addView(row);
            coverSection.body.addView(UiKit.caption(ctx,
                    "封面替换无法整批撤销（文本字段可以）。保存时与字段一起写入。"));

            online.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    fetchCoverOnline();
                }
            });
            pick.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    pickCoverFromFile();
                }
            });
            remove.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    pendingCover = new byte[0];
                    coverView.setImageDrawable(null);
                    coverInfo.setText("保存后移除封面");
                    coverSection.setState("已修改");
                    refreshSaveButton();
                }
            });
            export.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    exportCover();
                }
            });
            box.addView(coverSection.root);
        }

        // --------------------------------------------------------------
        // 基本信息
        // --------------------------------------------------------------

        private void buildBasicSection(LinearLayout box) {
            box.addView(UiKit.divider(ctx));
            final UiKit.Section section = UiKit.section(ctx, "基本信息", true);
            addField(section.body, "title", "标题");
            addField(section.body, "artist", "艺术家");
            addField(section.body, "album", "专辑");

            LinearLayout row = UiKit.horizontal(ctx);
            UiKit.margin(row, 0, 6, 0, 0);
            addCompactField(row, "year", "年份");
            addCompactField(row, "track", "音轨");
            addCompactField(row, "genre", "流派");
            section.body.addView(row);

            addField(section.body, "comment", "注释");

            // 两个本地修正工具（v0.1.80）：编码修正救回读错的乱码，清理文本去掉多余空格/全角
            LinearLayout tools = UiKit.horizontal(ctx);
            UiKit.margin(tools, 0, 8, 0, 0);
            Button fixEnc = UiKit.button(ctx, "编码修正", false);
            fixEnc.setTextSize(12f);
            Button tidy = UiKit.button(ctx, "清理文本", false);
            tidy.setTextSize(12f);
            tools.addView(fixEnc, new LinearLayout.LayoutParams(0, UiKit.dp(ctx, 40), 1f));
            LinearLayout.LayoutParams tlp =
                    new LinearLayout.LayoutParams(0, UiKit.dp(ctx, 40), 1f);
            tlp.setMargins(UiKit.dp(ctx, 6), 0, 0, 0);
            tools.addView(tidy, tlp);
            section.body.addView(tools);
            fixEnc.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    openEncodingFix();
                }
            });
            tidy.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    tidyText();
                }
            });
            box.addView(section.root);
        }

        /** 当前表单里某个字段的值。 */
        private String valueOf(String key) {
            EditText et = inputs.get(key);
            return et == null ? "" : et.getText().toString();
        }

        /**
         * 编码修正（v0.1.80）：把「按错误编码解出来」的乱码重新按 GBK / UTF-8 / Big5 解释一遍。
         *
         * <p>只对「每个字符都 ≤ U+00FF」的字符串有意义 —— 那才是典型的多字节文本被当成
         * Latin-1 解出来的样子（{@code Ã©} 这类）。真中文不需要修，直接提示。
         */
        private void openEncodingFix() {
            final String[] keys = {"title", "artist", "album"};
            boolean any = false;
            for (String k : keys) {
                if (looksMojibake(valueOf(k))) {
                    any = true;
                    break;
                }
            }
            if (!any) {
                host.toast("标题 / 艺术家 / 专辑看起来不是乱码，不需要修正");
                return;
            }
            final String[] charsets = {"GBK", "UTF-8", "Big5"};
            final String[] labels = new String[charsets.length + 1];
            labels[0] = "保持原样";
            for (int i = 0; i < charsets.length; i++) {
                StringBuilder sb = new StringBuilder("按 " + charsets[i] + " 重新解释：");
                sb.append(preview(keys, charsets[i]));
                labels[i + 1] = sb.toString();
            }
            new AlertDialog.Builder(ctx)
                    .setTitle("编码修正")
                    .setItems(labels, new android.content.DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(android.content.DialogInterface d, int which) {
                            if (which == 0) {
                                return;
                            }
                            String cs = charsets[which - 1];
                            for (String k : keys) {
                                String old = valueOf(k);
                                String now = reinterpret(old, cs);
                                if (!now.equals(old)) {
                                    EditText et = inputs.get(k);
                                    if (et != null) {
                                        et.setText(now);
                                    }
                                }
                            }
                            status.setText("已按 " + cs + " 重新解释，确认无误后保存");
                        }
                    })
                    .setNegativeButton("取消", null)
                    .show();
        }

        private String preview(String[] keys, String cs) {
            StringBuilder sb = new StringBuilder();
            for (String k : keys) {
                String now = reinterpret(valueOf(k), cs);
                if (!now.isEmpty()) {
                    if (sb.length() > 0) {
                        sb.append(" / ");
                    }
                    sb.append(now);
                }
            }
            return sb.length() == 0 ? "（空）" : sb.toString();
        }

        /** 本地清理：去多余空格 / 全角转半角 / 音轨补零（不走网络，也不碰封面）。 */
        private void tidyText() {
            int ops = TagFix.TRIM | TagFix.SPACES | TagFix.WIDTH | TagFix.TRACK;
            int n = 0;
            for (String k : TagFix.FIELDS) {
                EditText et = inputs.get(k);
                if (et == null) {
                    continue;
                }
                String old = et.getText().toString();
                String now = "track".equals(k)
                        ? TagFix.clean(TagFix.track(old), ops & ~TagFix.TRACK)
                        : TagFix.clean(old, ops);
                if (!now.equals(old)) {
                    et.setText(now);
                    n++;
                }
            }
            status.setText(n == 0 ? "没有需要清理的内容" : "已清理 " + n + " 项，确认无误后保存");
        }

        private void addField(LinearLayout parent, final String key, String label) {
            LinearLayout labelRow = UiKit.horizontal(ctx);
            labelRow.setGravity(Gravity.CENTER_VERTICAL);
            UiKit.margin(labelRow, 0, 8, 0, 2);
            labelRow.addView(UiKit.caption(ctx, label), new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            final TextView dot = UiKit.text(ctx, "● 已改", 11, UiKit.primary(), true);
            dot.setVisibility(View.INVISIBLE);
            labelRow.addView(dot);
            parent.addView(labelRow);

            final EditText et = UiKit.input(ctx, label);
            parent.addView(et);
            inputs.put(key, et);
            dots.put(key, dot);
            initial.put(key, "");
            wire(key, et, dot);
        }

        /** 年份 / 音轨 / 流派 三个短字段并排，省纵向空间。 */
        private void addCompactField(LinearLayout row, final String key, String label) {
            LinearLayout col = UiKit.vertical(ctx);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            if (row.getChildCount() > 0) {
                lp.setMargins(UiKit.dp(ctx, 6), 0, 0, 0);
            }
            row.addView(col, lp);

            LinearLayout labelRow = UiKit.horizontal(ctx);
            labelRow.setGravity(Gravity.CENTER_VERTICAL);
            labelRow.addView(UiKit.caption(ctx, label), new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            final TextView dot = UiKit.text(ctx, "●", 10, UiKit.primary(), true);
            dot.setVisibility(View.INVISIBLE);
            labelRow.addView(dot);
            col.addView(labelRow);

            final EditText et = UiKit.input(ctx, "");
            col.addView(et);
            inputs.put(key, et);
            dots.put(key, dot);
            initial.put(key, "");
            wire(key, et, dot);
        }

        private void wire(final String key, final EditText et, final TextView dot) {
            dot.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    et.setText(TextUtil.safeStr(initial.get(key)));
                }
            });
            et.addTextChangedListener(new android.text.TextWatcher() {
                @Override
                public void beforeTextChanged(CharSequence s, int a, int b, int c) {
                }

                @Override
                public void onTextChanged(CharSequence s, int a, int b, int c) {
                }

                @Override
                public void afterTextChanged(android.text.Editable s) {
                    boolean changed = !s.toString().trim()
                            .equals(TextUtil.safeStr(initial.get(key)).trim());
                    dot.setVisibility(changed ? View.VISIBLE : View.INVISIBLE);
                    refreshSaveButton();
                }
            });
        }

        /** 是否为「多字节文本被当 Latin-1 解出来」的样子：非 ASCII 但每个字符都 ≤ U+00FF。 */
        private static boolean looksMojibake(String s) {
            if (s == null || s.isEmpty()) {
                return false;
            }
            boolean high = false;
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c > 0xFF) {
                    return false;   // 已经是正常中文
                }
                if (c > 0x7F) {
                    high = true;
                }
            }
            return high;
        }

        /** 取回「原始字节」再按指定编码解一次；做不到就原样返回。 */
        private static String reinterpret(String s, String charset) {
            if (!looksMojibake(s)) {
                return s;
            }
            try {
                byte[] raw = s.getBytes("ISO-8859-1");
                String out = new String(raw, charset);
                // 解出来还是乱码（含替换符）就当作失败
                return out.indexOf('\uFFFD') >= 0 ? s : out;
            } catch (Throwable t) {
                return s;
            }
        }

        // --------------------------------------------------------------
        // 歌词
        // --------------------------------------------------------------

        private void buildLyricSection(LinearLayout box) {
            box.addView(UiKit.divider(ctx));
            lyricSection = UiKit.section(ctx, "歌词", false);
            lyricPreview = UiKit.caption(ctx, "读取中…");
            lyricPreview.setMaxLines(6);
            lyricSection.body.addView(lyricPreview);

            LinearLayout row = UiKit.horizontal(ctx);
            UiKit.margin(row, 0, 6, 0, 0);
            Button edit = UiKit.button(ctx, "编辑", false);
            edit.setTextSize(12.5f);
            Button online = UiKit.button(ctx, "在线取歌词", false);
            online.setTextSize(12.5f);
            Button clear = UiKit.button(ctx, "清除", false);
            clear.setTextSize(12.5f);
            row.addView(edit);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            lp.setMargins(UiKit.dp(ctx, 6), 0, 0, 0);
            row.addView(online, lp);
            LinearLayout.LayoutParams lp2 = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            lp2.setMargins(UiKit.dp(ctx, 6), 0, 0, 0);
            row.addView(clear, lp2);
            lyricSection.body.addView(row);

            lyricDot = UiKit.text(ctx, "● 已改", 11, UiKit.primary(), true);
            lyricDot.setVisibility(View.INVISIBLE);
            lyricSection.body.addView(lyricDot);

            edit.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    editLyrics();
                }
            });
            online.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    fetchLyricsOnline();
                }
            });
            clear.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    setLyrics("");
                }
            });
            box.addView(lyricSection.root);
        }

        private void editLyrics() {
            final EditText et = UiKit.input(ctx, "歌词正文（LRC 或纯文本）");
            et.setText(currentLyrics());
            et.setMinLines(10);
            et.setGravity(Gravity.TOP | Gravity.START);
            new UiKit.Builder(ctx)
                    .setTitle("编辑歌词")
                    .setView(et)
                    .setPositiveButton("确定",
                            new android.content.DialogInterface.OnClickListener() {
                                @Override
                                public void onClick(android.content.DialogInterface d, int w) {
                                    setLyrics(et.getText().toString());
                                }
                            })
                    .setNegativeButton("取消", null)
                    .show();
        }

        private String currentLyrics() {
            return pendingLyrics != null ? pendingLyrics : beforeLyrics;
        }

        private void setLyrics(String text) {
            pendingLyrics = text == null ? "" : text;
            updateLyricPreview();
            boolean changed = !pendingLyrics.trim().equals(beforeLyrics.trim());
            lyricDot.setVisibility(changed ? View.VISIBLE : View.INVISIBLE);
            lyricSection.setState(changed ? "已修改" : lineState(beforeLyrics));
            refreshSaveButton();
        }

        private void updateLyricPreview() {
            String text = currentLyrics();
            lyricPreview.setText(text.trim().isEmpty() ? "（无歌词）" : Lyrics.excerpt(text, 4));
        }

        private String lineState(String text) {
            if (text == null || text.trim().isEmpty()) {
                return "无";
            }
            return "已有 " + text.split("\n").length + " 行";
        }

        // --------------------------------------------------------------
        // 在线匹配
        // --------------------------------------------------------------

        private void buildOnlineSection(LinearLayout box) {
            box.addView(UiKit.divider(ctx));
            onlineSection = UiKit.section(ctx, "在线匹配", false);

            onlineSection.body.addView(UiKit.caption(ctx,
                    "文件名权重（越高越信文件名，越低越信已有标签）"));
            weightBar = UiKit.slider(ctx, host.repo.intVal("fn_weight",
                    NameWeight.DEFAULT_PERCENT), NameWeight.MAX_PERCENT);
            weightValue = UiKit.text(ctx, weightText(weightBar.getProgress()), 12.5f,
                    UiKit.primary(), true);
            onlineSection.body.addView(weightBar);
            onlineSection.body.addView(weightValue);
            weightBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    weightValue.setText(weightText(progress));
                    if (fromUser) {
                        host.repo.setInt("fn_weight", progress);
                    }
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {
                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {
                }
            });

            Button fetch = UiKit.button(ctx, "联网匹配（多源聚合）", false);
            UiKit.margin(fetch, 0, 8, 0, 0);
            fetch.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    fetchCandidates();
                }
            });
            onlineSection.body.addView(fetch);

            candidates = UiKit.vertical(ctx);
            onlineSection.body.addView(candidates);
            box.addView(onlineSection.root);
        }

        private void fetchCandidates() {
            status.setText("正在查询多源（MusicBrainz / Deezer / iTunes / 国内源）…");
            onlineSection.setExpanded(true);
            host.runTask("在线匹配标签", new Tasks.Job() {
                @Override
                public Object run() throws Exception {
                    Storage st = host.safeStorage();
                    Tags tags = Scanner.readTagsCheap(st, host.getContentResolver(), file);
                    Sources.Query q = new Sources.Query();
                    q.filenameCandidates.addAll(NameParser.candidatePairs(file.stem()));
                    q.embeddedTags.put("title", tags.get("title"));
                    q.embeddedTags.put("artist", tags.get("artist"));
                    q.localDuration = Scanner.durationOf(st, host.getContentResolver(), file);
                    if (q.localDuration != null) {
                        localDurSec = q.localDuration.doubleValue();
                    }
                    q.useCnSources = host.repo.bool("cn", true);
                    q.filenameWeight = NameWeight.fromPercent(weightBar.getProgress());
                    return Sources.aggregate(host.repo.mb, q, host.progressCallback(),
                            host.cancelToken());
                }
            }, new Tasks.Callback() {
                @Override
                public void done(Object result, Exception error) {
                    if (error != null) {
                        status.setText("查询失败：" + TextUtil.shortError(error));
                        return;
                    }
                    @SuppressWarnings("unchecked")
                    List<Sources.Candidate> list = (List<Sources.Candidate>) result;
                    if (list.isEmpty()) {
                        status.setText("所有数据源都没有返回候选（可稍后重试或关闭国内源）");
                        return;
                    }
                    status.setText("找到 " + list.size() + " 个候选，勾字段后点「填入表单」");
                    showCandidateCards(list);
                }
            });
        }

        /** 每条候选一张卡片：勾要填的字段，再点「填入表单」。 */
        private void showCandidateCards(List<Sources.Candidate> list) {
            candidates.removeAllViews();
            int limit = Math.min(list.size(), 10);
            for (int i = 0; i < limit; i++) {
                final Sources.Candidate c = list.get(i);
                LinearLayout card = UiKit.vertical(ctx);
                UiKit.margin(card, 0, 8, 0, 0);
                android.graphics.drawable.GradientDrawable bg =
                        new android.graphics.drawable.GradientDrawable();
                bg.setColor(UiKit.cardColor());
                bg.setCornerRadius(UiKit.dp(ctx, 10));
                bg.setStroke(UiKit.dp(ctx, 1), UiKit.lineColor());
                card.setBackground(bg);
                int p = UiKit.dp(ctx, 10);
                card.setPadding(p, p, p, p);

                String head = TextUtil.safeStr(c.artist);
                if (!TextUtil.safeStr(c.title).isEmpty()) {
                    head = head.isEmpty() ? c.title : head + " - " + c.title;
                }

                // 顶部：封面缩略图 + 文字（图异步到，占位块先撑住高度，避免列表跳动）
                LinearLayout top = UiKit.horizontal(ctx);
                top.setGravity(Gravity.TOP);
                ImageView thumb = new ImageView(ctx);
                LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                        UiKit.dp(ctx, 52), UiKit.dp(ctx, 52));
                thumb.setLayoutParams(tlp);
                thumb.setScaleType(ImageView.ScaleType.CENTER_CROP);
                android.graphics.drawable.GradientDrawable ph =
                        new android.graphics.drawable.GradientDrawable();
                ph.setColor(0x1A808080);
                ph.setCornerRadius(UiKit.dp(ctx, 6));
                thumb.setBackground(ph);
                top.addView(thumb);

                LinearLayout texts = UiKit.vertical(ctx);
                LinearLayout.LayoutParams vlp = new LinearLayout.LayoutParams(0,
                        LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
                vlp.setMargins(UiKit.dp(ctx, 10), 0, 0, 0);
                top.addView(texts, vlp);
                texts.addView(UiKit.text(ctx, head, 14, UiKit.textColor(), true));

                StringBuilder sub = new StringBuilder();
                if (!TextUtil.safeStr(c.album).isEmpty()) {
                    sub.append(c.album).append(" · ");
                }
                if (!TextUtil.safeStr(c.year).isEmpty()) {
                    sub.append(c.year).append(" · ");
                }
                String dur = durationText(c.duration, localDurSec);
                if (!dur.isEmpty()) {
                    sub.append(dur).append(" · ");
                }
                sub.append(c.source).append("  ")
                        .append(String.format(java.util.Locale.US, "%.2f", c.confidence));
                if (c.confidence < 0.50) {
                    sub.append("  ⚠低置信");
                }
                texts.addView(UiKit.caption(ctx, sub.toString()));
                card.addView(top);
                loadThumb(ctx, thumb, c.coverUrl);

                final Map<String, android.widget.CheckBox> boxes =
                        new LinkedHashMap<String, android.widget.CheckBox>();
                LinearLayout checks = UiKit.horizontal(ctx);
                UiKit.margin(checks, 0, 6, 0, 0);
                addCandidateCheck(checks, boxes, "title", "标题", c.title);
                addCandidateCheck(checks, boxes, "artist", "艺术家", c.artist);
                addCandidateCheck(checks, boxes, "album", "专辑", c.album);
                card.addView(checks);

                LinearLayout checks2 = UiKit.horizontal(ctx);
                addCandidateCheck(checks2, boxes, "year", "年份", c.year);
                addCandidateCheck(checks2, boxes, "genre", "流派", c.genre);
                card.addView(checks2);

                Button apply = UiKit.button(ctx, "填入表单", false);
                apply.setTextSize(12.5f);
                UiKit.margin(apply, 0, 6, 0, 0);
                apply.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        applyCandidate(c, boxes);
                    }
                });
                card.addView(apply);
                candidates.addView(card);
            }
            if (list.size() > limit) {
                candidates.addView(UiKit.caption(ctx,
                        "只显示前 " + limit + " 条（按置信度排序），其余略。"));
            }
        }

        private void addCandidateCheck(LinearLayout row,
                                       Map<String, android.widget.CheckBox> boxes,
                                       String key, String label, String value) {
            if (value == null || value.trim().isEmpty()) {
                return;
            }
            android.widget.CheckBox cb = UiKit.checkbox(ctx, label, true);
            cb.setTextSize(12);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            lp.setMargins(0, 0, UiKit.dp(ctx, 8), 0);
            row.addView(cb, lp);
            boxes.put(key, cb);
        }

        private void applyCandidate(Sources.Candidate c,
                                    Map<String, android.widget.CheckBox> boxes) {
            int filled = 0;
            for (Map.Entry<String, android.widget.CheckBox> e : boxes.entrySet()) {
                if (!e.getValue().isChecked()) {
                    continue;
                }
                String key = e.getKey();
                String value = candidateValue(c, key);
                EditText et = inputs.get(key);
                if (et != null && !value.isEmpty()) {
                    et.setText(value);
                    filled++;
                }
            }
            status.setText("已填入 " + filled + " 项（来源 " + c.source + "）");
            refreshSaveButton();
        }

        private String candidateValue(Sources.Candidate c, String key) {
            if ("title".equals(key)) {
                return TextUtil.safeStr(c.title);
            }
            if ("artist".equals(key)) {
                return TextUtil.safeStr(c.artist);
            }
            if ("album".equals(key)) {
                return TextUtil.safeStr(c.album);
            }
            if ("year".equals(key)) {
                return TextUtil.safeStr(c.year);
            }
            if ("genre".equals(key)) {
                return TextUtil.safeStr(c.genre);
            }
            return "";
        }

        // --------------------------------------------------------------
        // 封面：在线 / 本地
        // --------------------------------------------------------------

        /**
         * 把这一首的封面导出成同目录的 {@code cover.jpg / cover.png}（v0.1.80）。
         *
         * <p>很多老曲库的音频本身没有内嵌封面，封面是文件夹里一张图；反过来，
         * 从别处下来的单曲往往只有内嵌封面。导出之后同目录其它歌就能走「目录封面」显示，
         * 配合「封面导出 + 目录封面兜底」形成一个闭环，不必给每首重复塞图。
         */
        private void exportCover() {
            status.setText("正在导出封面…");
            host.runTask("导出封面", new Tasks.Job() {
                @Override
                public Object run() throws Exception {
                    Storage st = host.safeStorage();
                    byte[] art = pendingCover != null
                            ? (pendingCover.length > 0 ? pendingCover : null)
                            : Scanner.readCover(st, host.getContentResolver(), file);
                    if (art == null || art.length == 0) {
                        return "";
                    }
                    boolean png = art.length > 8 && (art[0] & 0xFF) == 0x89
                            && art[1] == 'P' && art[2] == 'N' && art[3] == 'G';
                    String ext = png ? ".png" : ".jpg";
                    String name = "cover" + ext;
                    VFile dir = new VFile(file.parentId, null, "",
                            "vnd.android.document/directory", 0L, 0L, true);
                    VFile target = null;
                    try {
                        for (VFile k : st.children(dir)) {
                            if (!k.dir && k.name.equalsIgnoreCase(name)) {
                                target = k;   // 已有同名文件就覆盖，别攒出 cover(1).jpg
                                break;
                            }
                        }
                    } catch (Throwable ignored) {
                    }
                    File tmp = File.createTempFile("mo_coverout_", ext);
                    try {
                        FileOutputStream out = new FileOutputStream(tmp);
                        out.write(art);
                        out.close();
                        if (target == null) {
                            target = st.createFile(dir, name, png ? "image/png" : "image/jpeg");
                        }
                        st.writeFromLocal(target, tmp);
                    } finally {
                        //noinspection ResultOfMethodCallIgnored
                        tmp.delete();
                    }
                    FolderCover.clear();          // 目录封面缓存要作废，否则新图要等重启才认
                    MediaRefresh.scan(ctx, target);  // 顺带让系统媒体库看见这张图
                    return name;
                }
            }, new Tasks.Callback() {
                @Override
                public void done(Object result, Exception error) {
                    if (error != null) {
                        status.setText("导出失败：" + TextUtil.shortError(error));
                        return;
                    }
                    String name = String.valueOf(result);
                    if (name.isEmpty()) {
                        status.setText("这一首没有封面可导出");
                        host.toast("没有内嵌封面可导出");
                        return;
                    }
                    status.setText("已导出 " + name + " 到同目录（其它歌可用作目录封面）");
                    host.toast("封面已导出：" + name);
                }
            });
        }

        private void fetchCoverOnline() {
            status.setText("正在查找封面…");
            host.runTask("获取封面", new Tasks.Job() {
                @Override
                public Object run() throws Exception {
                    Storage st = host.safeStorage();
                    Tags tags = Scanner.readTagsCheap(st, host.getContentResolver(), file);
                    Sources.Query q = new Sources.Query();
                    q.filenameCandidates.addAll(NameParser.candidatePairs(file.stem()));
                    q.embeddedTags.put("title", tags.get("title"));
                    q.embeddedTags.put("artist", tags.get("artist"));
                    q.localDuration = Scanner.durationOf(st, host.getContentResolver(), file);
                    q.useCnSources = host.repo.bool("cn", true);
                    q.filenameWeight = NameWeight.fromPercent(host.repo.intVal("fn_weight",
                            NameWeight.DEFAULT_PERCENT));
                    List<Sources.Candidate> list = Sources.aggregate(host.repo.mb, q,
                            host.progressCallback(), host.cancelToken());
                    for (Sources.Candidate c : list) {
                        if (host.cancelToken().isCancelled()) {
                            break;
                        }
                        if (c.coverUrl == null || c.coverUrl.isEmpty()) {
                            continue;
                        }
                        // Http 内部直接遍历 params，必须给空表（null 会 NPE）
                        byte[] bytes = Http.getBytes(c.coverUrl,
                                new java.util.HashMap<String, String>(),
                                new java.util.HashMap<String, String>(), 15000,
                                CoverArt.MAX_BYTES);
                        if (bytes != null && bytes.length > 0) {
                            return bytes;
                        }
                    }
                    return null;
                }
            }, new Tasks.Callback() {
                @Override
                public void done(Object result, Exception error) {
                    if (error != null) {
                        status.setText("封面获取失败：" + TextUtil.shortError(error));
                        return;
                    }
                    byte[] bytes = (byte[]) result;
                    if (bytes == null) {
                        status.setText("没有源提供这张专辑的封面（可「从文件选」）");
                        return;
                    }
                    applyPendingCover(bytes);
                    status.setText("封面已就绪，保存后写入");
                }
            });
        }

        private void pickCoverFromFile() {
            pendingPick = new CoverCallback() {
                @Override
                public void onPicked(byte[] bytes) {
                    applyPendingCover(bytes);
                    status.setText("已选择本地图片，保存后写入");
                }
            };
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("image/*");
            try {
                host.startActivityForResult(intent, REQ_PICK_COVER);
            } catch (Exception e) {
                pendingPick = null;
                status.setText("打不开文件选择器：" + TextUtil.shortError(e));
            }
        }

        private void applyPendingCover(byte[] bytes) {
            pendingCover = bytes;
            Bitmap bmp = decode(bytes, 240);
            if (bmp != null) {
                coverView.setImageBitmap(bmp);
            }
            int[] dim = CoverArt.dimensions(bytes);
            String mime = CoverArt.mimeOf(bytes);
            coverInfo.setText((mime.isEmpty() ? "未知格式"
                    : mime.replace("image/", "").toUpperCase())
                    + (dim[0] > 0 ? "  " + dim[0] + "×" + dim[1] : "")
                    + " · " + CoverArt.sizeText(bytes.length) + "\n保存后替换现有封面");
            coverSection.setState("已修改");
            refreshSaveButton();
        }

        // --------------------------------------------------------------
        // 读取 / 保存
        // --------------------------------------------------------------

        private void loadTags() {
            host.runTask("读取标签", new Tasks.Job() {
                @Override
                public Object run() throws Exception {
                    Storage st = host.safeStorage();
                    Tags tags = TagTransaction.read(st, host.getContentResolver(), file);
                    byte[] cover = Scanner.readCover(st, host.getContentResolver(), file);
                    return new Object[]{tags, cover};
                }
            }, new Tasks.Callback() {
                @Override
                public void done(Object result, Exception error) {
                    if (error != null) {
                        status.setText("读取失败：" + TextUtil.shortError(error));
                        return;
                    }
                    Object[] arr = (Object[]) result;
                    before = (Tags) arr[0];
                    byte[] cover = (byte[]) arr[1];
                    beforeLyrics = before.get(Tags.LYRICS);
                    fillFields();
                    showCover(cover);
                    updateLyricPreview();
                    lyricSection.setState(lineState(beforeLyrics));
                    status.setText(writable
                            ? "写入走事务层，失败原文件不动；改过的字段右侧有「●」。"
                            : "该格式不支持写标签（" + file.ext() + "），只能查看。");
                    refreshSaveButton();
                }
            });
        }

        private void fillFields() {
            for (Map.Entry<String, EditText> e : inputs.entrySet()) {
                String key = e.getKey();
                String value = before.get(key);
                e.getValue().setText(value);
                initial.put(key, value);
                TextView dot = dots.get(key);
                if (dot != null) {
                    dot.setVisibility(View.INVISIBLE);
                }
            }
        }

        private void showCover(byte[] cover) {
            if (cover == null || cover.length == 0) {
                coverInfo.setText("没有内嵌封面");
                coverView.setImageDrawable(null);
                return;
            }
            Bitmap bmp = decode(cover, 240);
            if (bmp != null) {
                coverView.setImageBitmap(bmp);
            }
            int[] dim = CoverArt.dimensions(cover);
            coverInfo.setText((dim[0] > 0 ? dim[0] + "×" + dim[1] + " · " : "")
                    + CoverArt.sizeText(cover.length));
        }

        private int changedCount() {
            int n = 0;
            for (Map.Entry<String, EditText> e : inputs.entrySet()) {
                String key = e.getKey();
                if (!e.getValue().getText().toString().trim()
                        .equals(TextUtil.safeStr(initial.get(key)).trim())) {
                    n++;
                }
            }
            if (pendingLyrics != null && !pendingLyrics.trim().equals(beforeLyrics.trim())) {
                n++;
            }
            if (pendingCover != null) {
                n++;
            }
            return n;
        }

        private void refreshSaveButton() {
            if (dialog == null) {
                return;
            }
            Button ok = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            if (ok == null) {
                return;
            }
            int n = changedCount();
            ok.setEnabled(n > 0 && writable);
            ok.setText(n > 0 ? "保存（" + n + " 项）" : "保存");
        }

        private void save() {
            if (!writable) {
                host.message("该格式不支持写标签",
                        file.ext() + " 只能读取。要改标签，先把它转成 MP3 / FLAC / M4A。");
                return;
            }
            final Map<String, String> updates = new LinkedHashMap<String, String>();
            StringBuilder diff = new StringBuilder();
            for (Map.Entry<String, EditText> e : inputs.entrySet()) {
                String key = e.getKey();
                String value = e.getValue().getText().toString().trim();
                String old = TextUtil.safeStr(initial.get(key));
                if (value.equals(old)) {
                    continue;
                }
                updates.put(key, value);
                diff.append(Tags.LABELS.get(key)).append("：")
                        .append(old.isEmpty() ? "（空）" : old)
                        .append("  →  ")
                        .append(value.isEmpty() ? "（清空）" : value)
                        .append('\n');
            }
            if (pendingLyrics != null && !pendingLyrics.trim().equals(beforeLyrics.trim())) {
                updates.put(Tags.LYRICS, pendingLyrics);
                diff.append("歌词：")
                        .append(beforeLyrics.trim().isEmpty() ? "（无）"
                                : beforeLyrics.split("\n").length + " 行")
                        .append("  →  ")
                        .append(pendingLyrics.trim().isEmpty() ? "（清空）"
                                : pendingLyrics.split("\n").length + " 行")
                        .append('\n');
            }
            if (pendingCover != null) {
                diff.append("封面：").append(pendingCover.length == 0 ? "移除"
                        : "替换为 " + CoverArt.sizeText(pendingCover.length)).append('\n');
            }
            if (updates.isEmpty() && pendingCover == null) {
                host.toast("没有修改");
                return;
            }
            diff.append("\n写入走事务层（副本 → 校验 → 回读），失败原文件不动。");
            if (pendingCover != null) {
                diff.append("\n注意：封面替换无法整批撤销。");
            }
            host.confirm("确认写入这些改动？", diff.toString(), new Runnable() {
                @Override
                public void run() {
                    host.runTask("写入标签", new Tasks.Job() {
                        @Override
                        public Object run() throws Exception {
                            Storage st = host.safeStorage();
                            return TagTransaction.applyWithCover(st,
                                    host.getContentResolver(), host, file, updates,
                                    pendingCover, true, "", host);
                        }
                    }, new Tasks.Callback() {
                        @Override
                        public void done(Object result, Exception error) {
                            String err = error != null ? TextUtil.shortError(error)
                                    : String.valueOf(result);
                            if (err.isEmpty()) {
                                host.toast("保存成功");
                                host.log("标签已保存：" + file.name, "success");
                                host.refreshBrowseTagOnly(
                                        java.util.Collections.singletonList(file));
                                dialog.dismiss();
                            } else {
                                status.setText(err);
                                host.log(err, "error");
                            }
                        }
                    });
                }
            });
        }

        // --------------------------------------------------------------

        private String weightText(int percent) {
            String hint = percent >= 50 ? "以文件名为准" : "以已有标签为准";
            return "文件名权重 " + percent + "% · " + hint;
        }

        private void fetchLyricsOnline() {
            status.setText("正在查询歌词（四个源并发）…");
            lyricSection.setExpanded(true);
            host.runTask("获取歌词", new Tasks.Job() {
                @Override
                public Object run() throws Exception {
                    Storage st = host.safeStorage();
                    List<VFile> one = new ArrayList<VFile>();
                    one.add(file);
                    Lyrics.FetchResult res = Lyrics.fetchMatches(st,
                            host.getContentResolver(), one, true, false,
                            NameWeight.fromPercent(weightBar.getProgress()), null,
                            host.progressCallback(), host.cancelToken(), host, null);
                    return res.matches.isEmpty() ? null : res.matches.get(0);
                }
            }, new Tasks.Callback() {
                @Override
                public void done(Object result, Exception error) {
                    if (error != null) {
                        status.setText("歌词获取失败：" + TextUtil.shortError(error));
                        return;
                    }
                    if (result == null) {
                        status.setText("没有找到歌词");
                        return;
                    }
                    Lyrics.Match m = (Lyrics.Match) result;
                    setLyrics(m.content);
                    status.setText("已取到歌词（" + (m.timeline ? "带时间轴" : "纯文本")
                            + "，来自 " + m.sourceLabel + "），保存后写入");
                }
            });
        }
    }

    // ------------------------------------------------------------------

    /**
     * 候选卡片缩略图缓存（按 URL，最多 24 张）。
     *
     * <p>只缓存已降采样的 52dp 小图，一张几十 KB；不缓存原图 —— 原图是
     * 800×800 起步，存十张就能吃掉十几 MB。
     */
    private static final android.util.LruCache<String, Bitmap> THUMBS =
            new android.util.LruCache<String, Bitmap>(24);

    /**
     * 异步取一张候选封面塞进缩略图位。
     *
     * <p>失败就保持占位底色：很多候选来自只提供文字、不给图的源，
     * 这里不能因为它把整张卡片打成错误态（用户要的是「能看出是哪张专辑」，
     * 不是「必须有图」）。
     */
    static void loadThumb(final android.content.Context context, final ImageView view, String url) {
        if (view == null || url == null) {
            return;
        }
        final String key = url.trim();
        if (key.isEmpty()) {
            return;
        }
        Bitmap cached = THUMBS.get(key);
        if (cached != null) {
            view.setImageBitmap(cached);
            return;
        }
        final int px = UiKit.dp(context, 52);
        com.dsh.musicorganizer.net.Net.io().execute(new Runnable() {
            @Override
            public void run() {
                final byte[] bytes = Http.getBytes(key, null, Sources.coverHeaders(key),
                        6000, CoverArt.MAX_BYTES);
                if (bytes == null) {
                    return;
                }
                final Bitmap bmp = decode(bytes, px);
                if (bmp == null) {
                    return;
                }
                THUMBS.put(key, bmp);
                view.post(new Runnable() {
                    @Override
                    public void run() {
                        view.setImageBitmap(bmp);
                    }
                });
            }
        });
    }

    /**
     * 「4:29（本地差 +2s）」里的时长部分；无时长返回空串。
     *
     * <p>候选时长单位是<b>秒</b>（各源在 {@code Sources} 里已统一），
     * 这里只在显示层换算，避免又引入一套单位。
     */
    static String durationText(Double sec, double localSec) {
        if (sec == null || sec.doubleValue() <= 0) {
            return "";
        }
        String base = com.dsh.musicorganizer.core.TrackInfo.duration(
                Math.round(sec.doubleValue() * 1000));
        if (localSec <= 0) {
            return base;
        }
        long diff = Math.round(sec.doubleValue() - localSec);
        if (Math.abs(diff) <= 1) {
            return base + "（时长一致）";
        }
        return base + "（本地差 " + (diff > 0 ? "+" : "-") + Math.abs(diff) + "s）";
    }

    /** 缩略图解码：先量尺寸再按 2 的幂降采样，避免一张 4000px 封面直接进内存。 */
    static Bitmap decode(byte[] bytes, int maxPx) {
        if (bytes == null || bytes.length == 0) {
            return null;
        }
        try {
            BitmapFactory.Options probe = new BitmapFactory.Options();
            probe.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(bytes, 0, bytes.length, probe);
            int sample = 1;
            while (probe.outWidth > 0 && probe.outWidth / (sample * 2) >= maxPx) {
                sample *= 2;
            }
            BitmapFactory.Options opts = new BitmapFactory.Options();
            opts.inSampleSize = sample;
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, opts);
        } catch (Exception e) {
            return null;
        }
    }

    static byte[] readUri(ContentResolver resolver, Uri uri) {
        InputStream in = null;
        try {
            in = resolver.openInputStream(uri);
            if (in == null) {
                return null;
            }
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                if (out.size() > MAX_COVER_BYTES) {
                    return null;
                }
            }
            return out.toByteArray();
        } catch (Exception e) {
            return null;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (Exception ignored) {
                }
            }
        }
    }
}
