package com.dsh.musicorganizer.core;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

import java.io.ByteArrayInputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;

/**
 * TTML 歌词解析（只做「转成 LRC」这一层，不渲染）。
 *
 * <p>国内几家源（QQ、酷狗的部分条目、YouTube Music 抓取）给的是 TTML：
 * {@code <tt><body><div><p begin="00:12.345" end="00:15.2">你好<span begin="00:12.345">你</span>…</p>}。
 * 这种格式绝大多数播放器都不认，直接写进文件等于没歌词，所以统一转成 LRC 再落盘。
 *
 * <p>解析用 JDK/Android 自带的 {@code javax.xml}（零第三方依赖）。关闭外部实体，
 * 避免用户导入未知来源歌词时触发 XXE。
 */
public final class Ttml {

    private Ttml() {
    }

    /** 是否看起来像 TTML（不做完整校验，够用即可）。 */
    public static boolean looksLike(String text) {
        if (text == null) {
            return false;
        }
        String s = text.trim();
        if (s.isEmpty() || s.charAt(0) != '<') {
            return false;
        }
        if (s.startsWith("<?xml") || s.startsWith("<tt") || s.startsWith("<TT")) {
            return true;
        }
        return s.contains("http://www.w3.org/ns/ttml")
                || s.contains("http://www.w3.org/2006/10/ttaf1");
    }

    /** 解析成行（含逐字时间）。解析失败返回空表，调用方保留原文。 */
    public static List<LyricsDoc.Line> parse(String ttml) {
        List<LyricsDoc.Line> out = new ArrayList<LyricsDoc.Line>();
        if (ttml == null || ttml.trim().isEmpty()) {
            return out;
        }
        Document doc = parseXml(ttml);
        if (doc == null) {
            return out;
        }
        List<Element> paragraphs = new ArrayList<Element>();
        collectByTag(doc.getDocumentElement(), "p", paragraphs);
        int order = 0;
        for (Element p : paragraphs) {
            long begin = parseTime(p.getAttribute("begin"), -1);
            if (begin < 0) {
                continue;
            }
            LyricsDoc.Line line = new LyricsDoc.Line();
            line.timeMs = begin;
            line.order = order++;
            StringBuilder text = new StringBuilder();
            collectWords(p, begin, text, line.words);
            line.text = text.toString().trim();
            if (line.text.isEmpty() && line.words.isEmpty()) {
                continue;
            }
            out.add(line);
        }
        Collections.sort(out, new Comparator<LyricsDoc.Line>() {
            @Override
            public int compare(LyricsDoc.Line a, LyricsDoc.Line b) {
                int c = Long.compare(a.timeMs, b.timeMs);
                return c != 0 ? c : Integer.compare(a.order, b.order);
            }
        });
        return out;
    }

    /** 转成普通 LRC（丢掉逐字时间，兼容所有播放器）。 */
    public static String toLrc(String ttml) {
        return toLrc(parse(ttml), false);
    }

    /** 转成增强型 LRC（保留 {@code <mm:ss.xx>} 逐字时间）。 */
    public static String toEnhancedLrc(String ttml) {
        return toLrc(parse(ttml), true);
    }

    /**
     * 合并同时间点的多轨（TTML 里译文常与原文同 begin）。
     *
     * <p>我们写出的双语 LRC 就是「同一时间戳两行」，所以译文直接跟在原文后面即可。
     */
    public static String toLrc(List<LyricsDoc.Line> lines, boolean enhanced) {
        if (lines == null || lines.isEmpty()) {
            return "";
        }
        List<LyricsDoc.Line> sorted = new ArrayList<LyricsDoc.Line>(lines);
        Collections.sort(sorted, new Comparator<LyricsDoc.Line>() {
            @Override
            public int compare(LyricsDoc.Line a, LyricsDoc.Line b) {
                int c = Long.compare(a.timeMs, b.timeMs);
                return c != 0 ? c : Integer.compare(a.order, b.order);
            }
        });
        StringBuilder sb = new StringBuilder(sorted.size() * 32);
        String lastTime = null;
        String lastText = null;
        for (LyricsDoc.Line line : sorted) {
            String time = LyricsDoc.format(line.timeMs);
            String text = enhanced ? enhancedBody(line) : line.text;
            if (text == null || text.trim().isEmpty()) {
                continue;
            }
            // 同一时间点、同一文本只写一次（多语言轨里重复的行很常见）
            if (time.equals(lastTime) && text.equals(lastText)) {
                continue;
            }
            sb.append(time).append(text).append('\n');
            lastTime = time;
            lastText = text;
        }
        return sb.toString();
    }

    private static String enhancedBody(LyricsDoc.Line line) {
        if (line.words == null || line.words.size() < 2) {
            return line.text;
        }
        StringBuilder sb = new StringBuilder();
        for (LyricsDoc.Word w : line.words) {
            // 逐字标记不带方括号：{@code <00:12.00>字}，带方括号写出来就是
            // {@code <[00:12.00]>字}，任何播放器都解析不了
            sb.append('<').append(stamp(w.timeMs)).append('>').append(w.text);
        }
        return sb.length() == 0 ? line.text : sb.toString();
    }

    /** {@code mm:ss.xx}（不含方括号）。 */
    private static String stamp(long ms) {
        long total = Math.max(0, ms);
        long m = total / 60000;
        long s = (total % 60000) / 1000;
        long cs = (total % 1000) / 10;
        return (m < 10 ? "0" + m : String.valueOf(m)) + ":"
                + (s < 10 ? "0" + s : String.valueOf(s)) + "."
                + (cs < 10 ? "0" + cs : String.valueOf(cs));
    }

    // ------------------------------------------------------------------

    private static Document parseXml(String xml) {
        try {
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setNamespaceAware(false);
            f.setExpandEntityReferences(false);
            // 关掉 DTD 与外部实体：歌词来自网络，不能让它读本地文件
            trySet(f, "http://apache.org/xml/features/disallow-doctype-decl", true);
            trySet(f, "http://xml.org/sax/features/external-general-entities", false);
            trySet(f, "http://xml.org/sax/features/external-parameter-entities", false);
            DocumentBuilder b = f.newDocumentBuilder();
            b.setEntityResolver(new org.xml.sax.EntityResolver() {
                @Override
                public org.xml.sax.InputSource resolveEntity(String publicId, String systemId) {
                    return new org.xml.sax.InputSource(new ByteArrayInputStream(new byte[0]));
                }
            });
            return b.parse(new ByteArrayInputStream(xml.getBytes("UTF-8")));
        } catch (Throwable t) {
            return null;
        }
    }

    private static void trySet(DocumentBuilderFactory f, String feature, boolean value) {
        try {
            f.setFeature(feature, value);
        } catch (Throwable ignored) {
        }
    }

    private static void collectByTag(Node node, String tag, List<Element> out) {
        if (node == null) {
            return;
        }
        if (node.getNodeType() == Node.ELEMENT_NODE) {
            Element e = (Element) node;
            String name = e.getTagName();
            int colon = name.indexOf(':');
            String local = colon >= 0 ? name.substring(colon + 1) : name;
            if (tag.equalsIgnoreCase(local)) {
                out.add(e);
            }
        }
        NodeList kids = node.getChildNodes();
        for (int i = 0; i < kids.getLength(); i++) {
            collectByTag(kids.item(i), tag, out);
        }
    }

    /**
     * 收集一段 {@code <p>} 的文本与逐字时间。
     *
     * <p>没有 {@code <span>} 的纯文本按行首时间处理；有 span 的按 span 的 begin 走。
     */
    private static void collectWords(Node node, long lineBegin, StringBuilder text,
                                     List<LyricsDoc.Word> words) {
        NodeList kids = node.getChildNodes();
        for (int i = 0; i < kids.getLength(); i++) {
            Node n = kids.item(i);
            if (n.getNodeType() == Node.TEXT_NODE || n.getNodeType() == Node.CDATA_SECTION_NODE) {
                String t = n.getNodeValue();
                if (t == null || t.isEmpty()) {
                    continue;
                }
                text.append(t);
                addWord(words, lineBegin, t);
            } else if (n.getNodeType() == Node.ELEMENT_NODE) {
                Element e = (Element) n;
                long begin = parseTime(attr(e, "begin"), lineBegin);
                if (isBreak(e)) {
                    text.append('\n');
                    continue;
                }
                StringBuilder inner = new StringBuilder();
                List<LyricsDoc.Word> innerWords = new ArrayList<LyricsDoc.Word>();
                collectWords(e, begin, inner, innerWords);
                text.append(inner);
                if (!innerWords.isEmpty()) {
                    words.addAll(innerWords);
                } else if (inner.length() > 0) {
                    addWord(words, begin, inner.toString());
                }
            }
        }
    }

    private static void addWord(List<LyricsDoc.Word> words, long time, String text) {
        if (text == null || text.isEmpty() || text.trim().isEmpty()) {
            return;
        }
        if (words.isEmpty()) {
            words.add(new LyricsDoc.Word(time, text));
            return;
        }
        // 纯空白并入上一个字，避免把空格单独算一个字
        LyricsDoc.Word last = words.get(words.size() - 1);
        if (last.timeMs == time) {
            last.text = last.text + text;
        } else {
            words.add(new LyricsDoc.Word(time, text));
        }
    }

    private static boolean isBreak(Element e) {
        String name = e.getTagName().toLowerCase();
        int colon = name.indexOf(':');
        String local = colon >= 0 ? name.substring(colon + 1) : name;
        return local.equals("br");
    }

    private static String attr(Element e, String name) {
        String v = e.getAttribute(name);
        if (v != null && !v.isEmpty()) {
            return v;
        }
        return e.getAttribute("tts:" + name);
    }

    /**
     * 解析 TTML 时间：{@code hh:mm:ss.mmm}、{@code mm:ss.mmm}、{@code 12.345}、
     * {@code 12.345s}、{@code 500ms}。
     *
     * <p>不能只认「正好两段冒号」：TTML 里 {@code 0:12.0}（分:秒）和
     * {@code 00:00:12.345}（时:分:秒）都合法，原先的正则把前者判成非法，
     * 逐字时间全部退化成行时间 → 逐字轨静默失效。
     */
    public static long parseTime(String value, long fallback) {
        if (value == null) {
            return fallback;
        }
        String v = value.trim();
        if (v.isEmpty()) {
            return fallback;
        }
        try {
            if (v.endsWith("ms")) {
                return Math.round(Double.parseDouble(v.substring(0, v.length() - 2).trim()));
            }
            String t = v.endsWith("s") ? v.substring(0, v.length() - 1).trim() : v;
            t = t.replace(',', '.');
            String[] parts = t.split(":");
            if (parts.length >= 2) {
                double seconds = Double.parseDouble(parts[parts.length - 1].trim());
                long minutes = Long.parseLong(parts[parts.length - 2].trim());
                long hours = parts.length >= 3 ? Long.parseLong(parts[0].trim()) : 0;
                return hours * 3600000L + minutes * 60000L + Math.round(seconds * 1000);
            }
            return Math.round(Double.parseDouble(t) * 1000);
        } catch (Exception ignored) {
        }
        return fallback;
    }

}
