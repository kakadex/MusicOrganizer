package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 曲库体检：把「哪些歌缺什么」一次算清楚。
 *
 * <p>以前想知道曲库里有多少首没标题、没封面、没歌词，只能靠文件页的徽标一个个翻。
 * 这里把逐个文件的事实（有无标题/歌手/专辑/封面/歌词）累加成分数 + 分类计数 + 问题清单。
 *
 * <p>纯计算，不碰文件：调用方负责读标签、判断封面/歌词，再把 {@link Item} 喂进来。
 */
public final class HealthCheck {

    private HealthCheck() {
    }

    /** 一个文件的体检事实。 */
    public static class Item {
        public String name = "";
        public String ext = "";
        public long size;
        public boolean title;
        public boolean artist;
        public boolean album;
        public boolean cover;
        public boolean lyrics;

        public Item() {
        }

        public Item(String name, String ext, long size) {
            this.name = name;
            this.ext = ext == null ? "" : ext.toLowerCase(java.util.Locale.US);
            this.size = size;
        }

        /** 缺失项的短标签，如「缺歌手/缺封面」；齐全时为空串。 */
        public String missing() {
            StringBuilder sb = new StringBuilder();
            append(sb, !title, "缺标题");
            append(sb, !artist, "缺歌手");
            append(sb, !album, "缺专辑");
            append(sb, !cover, "缺封面");
            append(sb, !lyrics, "缺歌词");
            return sb.toString();
        }

        /** 五个维度里满足几个（0~5）。 */
        public int score() {
            int n = 0;
            if (title) {
                n++;
            }
            if (artist) {
                n++;
            }
            if (album) {
                n++;
            }
            if (cover) {
                n++;
            }
            if (lyrics) {
                n++;
            }
            return n;
        }

        private static void append(StringBuilder sb, boolean cond, String label) {
            if (!cond) {
                return;
            }
            if (sb.length() > 0) {
                sb.append('/');
            }
            sb.append(label);
        }
    }

    /** 体检结果。 */
    public static class Report {
        public int audio;
        public int lyricFiles;
        public long bytes;
        public int noTitle;
        public int noArtist;
        public int noAlbum;
        public int noCover;
        public int noLyrics;
        /** 五个维度全部满足的首数。 */
        public int complete;
        /** 扩展名 → 首数（按首数倒序）。 */
        public final Map<String, Integer> byExt = new LinkedHashMap<String, Integer>();
        /** 有问题的最多保留 200 条，够界面滚动看。 */
        public final List<Item> issues = new ArrayList<Item>();

        public void add(Item it) {
            if (it == null) {
                return;
            }
            audio++;
            bytes += it.size;
            if (!it.title) {
                noTitle++;
            }
            if (!it.artist) {
                noArtist++;
            }
            if (!it.album) {
                noAlbum++;
            }
            if (!it.cover) {
                noCover++;
            }
            if (!it.lyrics) {
                noLyrics++;
            }
            String ext = (it.ext == null || it.ext.isEmpty()) ? "其它" : it.ext;
            Integer n = byExt.get(ext);
            byExt.put(ext, Integer.valueOf(n == null ? 1 : n.intValue() + 1));
            if (it.score() >= 5) {
                complete++;
            } else if (issues.size() < 200) {
                issues.add(it);
            }
        }

        /** 完整度（0~100）：五个维度逐首平均。 */
        public int completeness() {
            if (audio == 0) {
                return 0;
            }
            int satisfied = audio * 5 - (noTitle + noArtist + noAlbum + noCover + noLyrics);
            if (satisfied < 0) {
                satisfied = 0;
            }
            return (int) Math.round(satisfied * 100.0 / (audio * 5.0));
        }

        /** 齐全（五个维度都满足）的首数。 */
        public int complete() {
            return complete;
        }

        /** 一句话结论。 */
        public String headline() {
            if (audio == 0) {
                return "还没有扫描到音频文件";
            }
            return "完整度 " + completeness() + "% · 共 " + audio + " 首";
        }

        /** 缺失项汇总（跳过 0）。 */
        public List<String> lines() {
            List<String> out = new ArrayList<String>();
            addLine(out, noTitle, "缺标题");
            addLine(out, noArtist, "缺歌手");
            addLine(out, noAlbum, "缺专辑");
            addLine(out, noCover, "缺封面");
            addLine(out, noLyrics, "缺歌词");
            return out;
        }

        /** 「mp3 620 首 · flac 88 首」这种，按首数倒序。 */
        public String extLine() {
            List<Map.Entry<String, Integer>> list =
                    new ArrayList<Map.Entry<String, Integer>>(byExt.entrySet());
            java.util.Collections.sort(list, new java.util.Comparator<Map.Entry<String, Integer>>() {
                @Override
                public int compare(Map.Entry<String, Integer> a, Map.Entry<String, Integer> b) {
                    return b.getValue().intValue() - a.getValue().intValue();
                }
            });
            StringBuilder sb = new StringBuilder();
            for (Map.Entry<String, Integer> e : list) {
                if (sb.length() > 0) {
                    sb.append(" · ");
                }
                String key = e.getKey();
                if (key.startsWith(".")) {
                    key = key.substring(1);
                }
                sb.append(key).append(' ').append(e.getValue().intValue()).append(" 首");
            }
            return sb.toString();
        }

        private static void addLine(List<String> out, int n, String label) {
            if (n > 0) {
                out.add(label + " " + n + " 首");
            }
        }
    }

    /** 大小格式化（1024 进制，保留一位小数）。 */
    public static String size(long bytes) {
        if (bytes < 1024) {
            return bytes + " B";
        }
        double kb = bytes / 1024.0;
        if (kb < 1024) {
            return String.format(java.util.Locale.US, "%.1f KB", kb);
        }
        double mb = kb / 1024.0;
        if (mb < 1024) {
            return String.format(java.util.Locale.US, "%.1f MB", mb);
        }
        return String.format(java.util.Locale.US, "%.2f GB", mb / 1024.0);
    }
}
