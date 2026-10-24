package com.dsh.musicorganizer.ui;

import com.dsh.musicorganizer.core.BatchMemory;
import com.dsh.musicorganizer.core.BatchSkip;
import com.dsh.musicorganizer.core.CoverBatch;
import com.dsh.musicorganizer.core.Lyrics;
import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.TagBatch;
import com.dsh.musicorganizer.core.TagFill;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 文件页「多选后的批量操作」。把原来只存在于整理页的链路（匹配 → 预览 → 事务写入）
 * 对「任意一批选中文件」复用，避免用户在两个页签之间来回跳。
 *
 * <p>所有写盘都走 {@link com.dsh.musicorganizer.core.TagTransaction} 与各批次的
 * {@code writeMatches}，不会绕过事务层；预览一律先弹，用户勾选确认后才落盘。
 */
public final class BatchActions {

    private BatchActions() {
    }

    /** 合并「全局覆盖开关」与「字段级自定义」，与整理页用的是同一套策略。 */
    static Map<String, Integer> fieldModes(MainActivity host) {
        Map<String, Integer> modes = TagFill.defaultModes(
                host.repo.bool("tag_overwrite", true));
        Map<String, Integer> custom = host.repo.tagFieldModes();
        for (Map.Entry<String, Integer> e : custom.entrySet()) {
            modes.put(e.getKey(), e.getValue());
        }
        return modes;
    }

    private static double weight(MainActivity host) {
        return NameWeight.fromPercent(host.repo.intVal("fn_weight",
                NameWeight.DEFAULT_PERCENT));
    }

    private static String policySummary(Map<String, Integer> modes) {
        int overwrite = 0;
        int supplement = 0;
        int disabled = 0;
        for (Integer v : modes.values()) {
            int m = v == null ? TagFill.SUPPLEMENT : v.intValue();
            if (m == TagFill.OVERWRITE) {
                overwrite++;
            } else if (m == TagFill.DISABLED) {
                disabled++;
            } else {
                supplement++;
            }
        }
        return "覆盖 " + overwrite + " / 只补空 " + supplement
                + (disabled > 0 ? " / 不写 " + disabled : "");
    }

    // ------------------------------------------------------------------
    // 批量标签
    // ------------------------------------------------------------------

    public static void tags(final MainActivity host, final List<VFile> files,
                            final BatchMemory memory) {
        if (files == null || files.isEmpty()) {
            host.toast("没有选中文件");
            return;
        }
        final Map<String, Integer> modes = fieldModes(host);
        final double weight = weight(host);
        final boolean cn = host.repo.bool("cn", true);
        host.confirm("批量匹配标签",
                "对选中的 " + files.size() + " 首联网匹配（" + policySummary(modes) + "），"
                        + "先预览再写入。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        matchTags(host, files, memory, modes, weight, cn);
                    }
                });
    }

    /** 真正跑匹配 → 预览（「重新查询」复用这一段，不再重复弹确认框）。 */
    private static void matchTags(final MainActivity host, final List<VFile> files,
                                  final BatchMemory memory, final Map<String, Integer> modes,
                                  final double weight, final boolean cn) {
        final BatchSkip skip = new BatchSkip();
        host.runTask("匹配标签", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return TagBatch.fetchMatches(st, host.getContentResolver(), host.repo.mb, files,
                        modes, weight, cn, null, host.progressCallback(), host.cancelToken(),
                        host, memory, skip);
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                @SuppressWarnings("unchecked")
                final List<TagBatch.Match> matches = (List<TagBatch.Match>) result;
                if (host.lastTaskStopped()) {
                    host.toast("已停止匹配");
                    return;
                }
                final Runnable preview = new Runnable() {
                    @Override
                    public void run() {
                        if (matches.isEmpty()) {
                            host.message("没有可写的标签",
                                    "选中的文件都没匹配到可写入的字段（也可能已按策略跳过）。");
                            return;
                        }
                        TagPreview.showBatch(host, matches, policySummary(modes),
                                new TagPreview.OnConfirm() {
                                    @Override
                                    public void confirmed(List<TagBatch.Match> selected) {
                                        writeTags(host, selected, memory);
                                    }
                                });
                    }
                };
                boolean hasOther = !matches.isEmpty();
                if (offerRetry(host, skip, memory, hasOther ? "先看其它 " + matches.size() + " 首"
                                : null,
                        new Runnable() {
                            @Override
                            public void run() {
                                matchTags(host, skip.memoryFiles(), memory, modes, weight, cn);
                            }
                        }, hasOther ? preview : null)) {
                    return;
                }
                preview.run();
            }
        });
    }

    private static void writeTags(final MainActivity host, final List<TagBatch.Match> selected,
                                  final BatchMemory memory) {
        host.runTask("写入标签", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                List<String> errors = new ArrayList<String>();
                int[] r = TagBatch.writeMatches(st, host.getContentResolver(), host,
                        selected, host.progressCallback(), host.cancelToken(), host, errors,
                        memory);
                return new Object[]{r, errors};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                Object[] arr = (Object[]) result;
                int[] r = (int[]) arr[0];
                @SuppressWarnings("unchecked")
                List<String> errors = (List<String>) arr[1];
                host.log("批量标签：成功 " + r[0] + "，跳过 " + r[1] + "，失败 " + r[2],
                        r[2] > 0 ? "warning" : "success");
                for (String e : errors) {
                    host.log(e, "warning");
                }
                host.toast("标签写入 " + r[0] + " 首，失败 " + r[2] + " 首");
                // 只刷新真正写过的文件：列表不重建，其它行的已读标签不会被清掉
                List<VFile> touched = new ArrayList<VFile>();
                for (TagBatch.Match m : selected) {
                    if (m != null && m.file != null) {
                        touched.add(m.file);
                    }
                }
                host.refreshBrowseTagOnly(touched);
            }
        });
    }

    // ------------------------------------------------------------------
    // 批量歌词
    // ------------------------------------------------------------------

    public static void lyrics(final MainActivity host, final List<VFile> files,
                              final BatchMemory memory) {
        if (files == null || files.isEmpty()) {
            host.toast("没有选中文件");
            return;
        }
        final boolean embed = host.repo.bool("lrc_embed", true);
        final double weight = weight(host);
        host.confirm("批量获取歌词",
                "对选中的 " + files.size() + " 首并发查询四个歌词源"
                        + (embed ? "，写入 .lrc 并嵌入标签" : "，只写同名 .lrc")
                        + "。先预览再写入。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        matchLyrics(host, files, memory, embed, weight);
                    }
                });
    }

    /** 真正跑歌词匹配 → 预览（「重新查询」复用这一段）。 */
    private static void matchLyrics(final MainActivity host, final List<VFile> files,
                                    final BatchMemory memory, final boolean embed,
                                    final double weight) {
        final BatchSkip skip = new BatchSkip();
        host.runTask("匹配歌词", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return Lyrics.fetchMatches(st, host.getContentResolver(),
                        files, true, false, weight, null,
                        host.progressCallback(), host.cancelToken(), host, memory, skip);
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                if (host.lastTaskStopped()) {
                    host.toast("已停止匹配");
                    return;
                }
                final Lyrics.FetchResult res = (Lyrics.FetchResult) result;
                final List<Lyrics.Match> matches = res.matches;
                final Runnable preview = new Runnable() {
                    @Override
                    public void run() {
                        if (matches == null || matches.isEmpty()) {
                            host.message("没有匹配到歌词", res.explain());
                            return;
                        }
                        LyricsPreview.showBatch(host, matches,
                                new LyricsPreview.OnConfirm() {
                                    @Override
                                    public void confirmed(List<Lyrics.Match> selected) {
                                        writeLyrics(host, selected, embed, memory);
                                    }
                                });
                    }
                };
                boolean hasOther = matches != null && !matches.isEmpty();
                if (offerRetry(host, skip, memory, hasOther ? "先看其它 " + matches.size() + " 首"
                                : null,
                        new Runnable() {
                            @Override
                            public void run() {
                                matchLyrics(host, skip.memoryFiles(), memory, embed, weight);
                            }
                        }, hasOther ? preview : null)) {
                    return;
                }
                preview.run();
            }
        });
    }

    private static void writeLyrics(final MainActivity host, final List<Lyrics.Match> selected,
                                    final boolean embed, final BatchMemory memory) {
        host.runTask("写入歌词", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return Lyrics.writeMatches(st, host.getContentResolver(), host, selected,
                        true, embed, host.progressCallback(), host.cancelToken(), host, memory);
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                int[] r = (int[]) result;
                host.log("批量歌词：成功 " + r[0] + "，跳过 " + r[1] + "，失败 " + r[2],
                        r[2] > 0 ? "warning" : "success");
                host.toast("歌词写入 " + r[0] + " 首，失败 " + r[2] + " 首");
                // 歌词只改文件内容、不改文件数量：走定向刷新，不必重扫目录
                List<VFile> touched = new ArrayList<VFile>();
                for (Lyrics.Match m : selected) {
                    if (m != null && m.file != null) {
                        touched.add(m.file);
                    }
                }
                host.refreshBrowseTagOnly(touched);
            }
        });
    }

    // ------------------------------------------------------------------
    // 批量封面
    // ------------------------------------------------------------------

    public static void covers(final MainActivity host, final List<VFile> files,
                              final BatchMemory memory) {
        if (files == null || files.isEmpty()) {
            host.toast("没有选中文件");
            return;
        }
        final boolean overwrite = host.repo.bool("cover_overwrite", false);
        final boolean cn = host.repo.bool("cn", true);
        final double weight = weight(host);
        host.confirm("批量补封面",
                (overwrite ? "将替换已有封面。" : "只补没有封面的文件。")
                        + "\n先匹配（只读），预览勾选后再下载写入。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        matchCovers(host, files, memory, overwrite, cn, weight);
                    }
                });
    }

    /** 真正跑封面匹配 → 预览（「重新查询」复用这一段）。 */
    private static void matchCovers(final MainActivity host, final List<VFile> files,
                                    final BatchMemory memory, final boolean overwrite,
                                    final boolean cn, final double weight) {
        final BatchSkip skip = new BatchSkip();
        host.runTask("匹配封面", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return CoverBatch.fetchMatches(st, host.getContentResolver(),
                        host.repo.mb, files, weight, cn, overwrite,
                        host.progressCallback(), host.cancelToken(), host, memory, skip);
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                final CoverBatch.Result res = (CoverBatch.Result) result;
                final Runnable preview = new Runnable() {
                    @Override
                    public void run() {
                        if (res.isEmpty()) {
                            host.message("没有可补的封面", res.explain());
                            return;
                        }
                        CoverPreview.showBatch(host, res.matches,
                                new CoverPreview.OnConfirm() {
                                    @Override
                                    public void confirmed(List<CoverBatch.Match> selected) {
                                        writeCovers(host, selected, memory);
                                    }
                                });
                    }
                };
                boolean hasOther = !res.isEmpty();
                if (offerRetry(host, skip, memory,
                        hasOther ? "先看其它 " + res.matches.size() + " 首" : null,
                        new Runnable() {
                            @Override
                            public void run() {
                                matchCovers(host, skip.memoryFiles(), memory, overwrite, cn,
                                        weight);
                            }
                        }, hasOther ? preview : null)) {
                    return;
                }
                preview.run();
            }
        });
    }

    // ------------------------------------------------------------------
    // 「按记忆跳过」的重新查询入口
    // ------------------------------------------------------------------

    /**
     * 本次匹配里有一部分歌因为「上次已经查过」而没联网（见 {@link BatchSkip}）。
     *
     * <p>以前界面只会打一行「按记忆跳过 N 首」就结束，用户想重查这几首没有任何入口。
     * 这里弹一个三选一：立刻重查 / 先看其它结果 / 取消。重查前会把这些歌的记忆删掉，
     * 否则下一轮照样跳过。
     *
     * @param continueText 「先看其它结果」的按钮文案；null 表示没有其它结果可看
     * @return true 表示已经弹了对话框，调用方不要再继续往下走
     */
    private static boolean offerRetry(final MainActivity host, final BatchSkip skip,
                                      final BatchMemory memory, String continueText,
                                      final Runnable onRetry, final Runnable onContinue) {
        final List<VFile> skipped = skip == null ? null : skip.memoryFiles();
        if (skipped == null || skipped.isEmpty()) {
            return false;
        }
        final int n = skipped.size();
        String msg = "这些歌上次已经查过了（确认查不到或已写入），本次没有联网。\n\n"
                + "如果上次是网络不稳、源站临时没结果，可以现在重新查询这 " + n + " 首"
                + "（会先清掉这些歌的匹配记忆）。";
        Runnable retry = new Runnable() {
            @Override
            public void run() {
                if (memory != null) {
                    List<String> keys = new ArrayList<String>();
                    for (VFile f : skipped) {
                        keys.add(TagBatch.memKey(f));
                    }
                    int removed = memory.forgetAll(keys);
                    host.log("重新联网查询 " + n + " 首（清掉 " + removed + " 条匹配记忆）", "info");
                } else {
                    host.log("重新联网查询 " + n + " 首", "info");
                }
                onRetry.run();
            }
        };
        host.choose("有 " + n + " 首按记忆跳过", msg,
                "重新查询这 " + n + " 首", retry,
                continueText, onContinue,
                "取消");
        return true;
    }

    private static void writeCovers(final MainActivity host, final List<CoverBatch.Match> selected,
                                    final BatchMemory memory) {
        host.runTask("写入封面", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                return CoverBatch.writeMatches(st, host.getContentResolver(), host, selected,
                        host.progressCallback(), host.cancelToken(), host, memory);
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                int[] r = (int[]) result;
                host.log("批量封面：成功 " + r[0] + "，跳过 " + r[1] + "，失败 " + r[2],
                        r[2] > 0 ? "warning" : "success");
                host.toast("封面写入 " + r[0] + " 首，失败 " + r[2] + " 首");
                List<VFile> touched = new ArrayList<VFile>();
                for (CoverBatch.Match m : selected) {
                    if (m != null && m.file != null) {
                        touched.add(m.file);
                    }
                }
                host.refreshBrowseTagOnly(touched);
            }
        });
    }

    // ------------------------------------------------------------------
    // 按标签重命名 / 删除
    // ------------------------------------------------------------------

    /**
     * 按模板重命名（v0.1.31 起格式可编辑）。
     *
     * <p>原来写死成「艺人 - 歌名」，现在交给 {@link RenameDialog}：模板可改、预设一键换、
     * 实时预览「旧名 → 新名」，确认后走长任务改名（可暂停/取消）。
     */
    public static void renameByTag(final MainActivity host, final List<VFile> files) {
        RenameDialog.show(host, files);
    }

    /** 目标文件名；标题为空返回 ""。非法字符一律换成下划线。 */
    static String targetName(Tags tags, VFile f) {
        String title = tags.get("title").trim();
        if (title.isEmpty()) {
            return "";
        }
        String artist = tags.get("artist").trim();
        String base = artist.isEmpty() ? title : artist + " - " + title;
        String safe = sanitize(base);
        if (safe.length() > 90) {
            safe = safe.substring(0, 90).trim();
        }
        return safe.isEmpty() ? "" : safe + f.ext();
    }

    static String sanitize(String name) {
        StringBuilder sb = new StringBuilder(name.length());
        String bad = "\\/:*?\"<>|";
        for (int i = 0; i < name.length(); i++) {
            char c = name.charAt(i);
            if (bad.indexOf(c) >= 0 || c < 0x20) {
                sb.append('_');
            } else {
                sb.append(c);
            }
        }
        String out = sb.toString().trim();
        // 去掉开头的点，避免变成隐藏文件
        while (out.startsWith(".")) {
            out = out.substring(1);
        }
        return out;
    }

    public static void delete(final MainActivity host, final List<VFile> files) {
        if (files == null || files.isEmpty()) {
            host.toast("没有选中文件");
            return;
        }
        long bytes = 0;
        for (VFile f : files) {
            bytes += f.size;
        }
        host.confirm("删除 " + files.size() + " 个文件",
                "共 " + TextUtil.formatSize(bytes) + "，删除后无法恢复（不进回收站）。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        host.runTask("删除文件", new Tasks.Job() {
                            @Override
                            public Object run() throws Exception {
                                Storage st = host.safeStorage();
                                int ok = 0;
                                int failed = 0;
                                for (VFile f : files) {
                                    if (host.cancelToken().isCancelled()) {
                                        break;
                                    }
                                    if (st.delete(f)) {
                                        ok++;
                                    } else {
                                        failed++;
                                    }
                                }
                                return new int[]{ok, failed};
                            }
                        }, new Tasks.Callback() {
                            @Override
                            public void done(Object result, Exception error) {
                                if (error != null) {
                                    host.fail(error);
                                    return;
                                }
                                int[] r = (int[]) result;
                                host.log("删除文件：成功 " + r[0] + "，失败 " + r[1],
                                        r[1] > 0 ? "warning" : "success");
                                host.toast("已删除 " + r[0] + " 个"
                                        + (r[1] > 0 ? "，失败 " + r[1] : ""));
                                host.refreshBrowseAfterChange();
                            }
                        });
                    }
                });
    }
}
