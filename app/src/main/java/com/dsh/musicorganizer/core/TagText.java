package com.dsh.musicorganizer.core;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/**
 * 标签文本解码的公共容错层（v0.1.45）。
 *
 * <p>为什么需要这一层：ID3 / Vorbis Comment / MP4 atom 都规定文本用 UTF-8，
 * 但国产工具链（千千静听、百度音乐、以及各种「一键改名」小工具）实际写出来的
 * 常常不是 UTF-8。实测样本里有三种：
 * <ol>
 *   <li><b>声明 UTF-8、内容是 GBK</b>：中文词的 GBK 字节大多以 {@code CB}/{@code B2} 这类开头，
 *       它们不是合法的 UTF-8 起始，按 UTF-8 硬解就是一串 {@code U+FFFD}；</li>
 *   <li><b>GBK 先被当成 Latin-1、再存成 UTF-8</b>（双重编码）：UTF-8 解码合法，
 *       但结果是一串拉丁重音字符，必须反解回字节再用 GBK 解；</li>
 *   <li><b>声明 Latin-1、内容是 UTF-8</b>：按 Latin-1 解得 {@code ä½ å¥½}。</li>
 * </ol>
 *
 * <p>三层都兜住，且**都不误伤正常的 UTF-8 中文标签** —— 判断依据是
 * 「严格 UTF-8 能否解码」+「解出来有没有汉字」，不是靠猜。
 *
 * <p>纯 Java（{@code java.nio} + GBK），零 Android 依赖，可在桌面 JVM 回归。
 */
public final class TagText {

    private static final Charset GBK = Charset.forName("GBK");

    private TagText() {
    }

    /**
     * {@code encoding=3}（UTF-8）的解码，带 GBK 回退与双重编码反解。
     *
     * <p>用 {@code CodingErrorAction.REPORT} 严格解码，而不是默认的「替换字符」，
     * 就是为了能区分「真的 UTF-8」与「冒充 UTF-8」—— 默认策略下两者都报告成功。
     */
    public static String decodeUtf8(byte[] payload) {
        if (payload == null || payload.length == 0) {
            return "";
        }
        String strict = strictUtf8(payload);
        if (strict != null) {
            String fixed = undoDoubleEncoding(strict);
            return stripNul(fixed == null ? strict : fixed);
        }
        // 非法 UTF-8：多半是 GBK 冒充
        String gbk = tryGbk(payload);
        if (gbk != null) {
            return stripNul(gbk);
        }
        // 都不是：按 UTF-8 宽容解（会带替换字符，但至少不丢内容）
        return stripNul(new String(payload, StandardCharsets.UTF_8));
    }

    /**
     * {@code encoding=0}（ISO-8859-1）的解码。
     *
     * <p>国内老软件写中文标签时，帧头声明 ISO-8859-1、实际存 GBK —— 按规范解码，
     * 每个汉字（两个高位字节）就变成两个拉丁重音字符，看起来就是「标签乱码」。
     *
     * <p>顺序：先看是不是「真 UTF-8 却标成 Latin-1」（这种也常见），再试 GBK，
     * 最后才老老实实按 Latin-1 返回。
     */
    public static String decodeLatin1OrGbk(byte[] payload) {
        if (payload == null || payload.length == 0) {
            return "";
        }
        // ① 有的工具把 UTF-8 中文写成 enc=0：能严格解出汉字就信它
        String strict = strictUtf8(payload);
        if (strict != null && containsCjk(strict)) {
            return stripNul(strict);
        }
        String latin = new String(payload, StandardCharsets.ISO_8859_1);
        if (!looksLikeGbk(payload)) {
            return stripNul(latin);
        }
        String gbk = tryGbk(payload);
        if (gbk != null) {
            return stripNul(gbk);
        }
        return stripNul(latin);
    }

    /**
     * 反解「GBK → 当成 Latin-1 → 再编码成 UTF-8」这一层错。
     *
     * <p>判定条件刻意收得紧，避免误伤真正的西文标签（Café / Señor）：
     * <ul>
     *   <li>原文一个汉字都没有（有汉字说明解码已经是对的）；</li>
     *   <li>所有字符都落在 Latin-1 区（有超出 0xFF 的字符就不是这种错法）；</li>
     *   <li>高位字符至少 2 个（单个 é 可能真是法语，不动）；</li>
     *   <li>反解回字节后用 GBK 解，结果必须含汉字且没有替换字符。</li>
     * </ul>
     *
     * @return 修正后的文本；不像双重编码时返回 {@code null}（调用方保留原值）
     */
    static String undoDoubleEncoding(String s) {
        if (s == null || s.isEmpty() || containsCjk(s)) {
            return null;
        }
        int high = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x80) {
                continue;
            }
            if (c > 0xFF) {
                return null;
            }
            high++;
        }
        if (high < 2) {
            return null;
        }
        byte[] bytes = s.getBytes(StandardCharsets.ISO_8859_1);
        return tryGbk(bytes);
    }

    /** 严格 UTF-8 解码；非法返回 {@code null}。 */
    private static String strictUtf8(byte[] payload) {
        try {
            CharsetDecoder dec = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT);
            return dec.decode(ByteBuffer.wrap(payload)).toString();
        } catch (CharacterCodingException e) {
            return null;
        }
    }

    /**
     * 按 GBK 解码；结果没有汉字、或含替换字符时返回 {@code null}。
     *
     * <p>「必须含汉字」这条很关键：GBK 的双字节范围极宽，几乎任何高位字节对都能
     * 解出**某个**字符，不设这道关就变成「随便什么都给个汉字」，反而更糟。
     */
    private static String tryGbk(byte[] payload) {
        if (payload == null || payload.length == 0) {
            return null;
        }
        try {
            String gbk = new String(payload, GBK);
            if (containsCjk(gbk) && gbk.indexOf('\uFFFD') < 0) {
                return gbk;
            }
        } catch (Exception ignored) {
            // GBK 不可用（理论上不会发生）：当作解不出
        }
        return null;
    }

    private static boolean looksLikeGbk(byte[] b) {
        for (int i = 0; i + 1 < b.length; i++) {
            int h = b[i] & 0xFF;
            int l = b[i + 1] & 0xFF;
            // GBK 双字节：首字节 0x81–0xFE，次字节 0x40–0xFE（0x7F 除外）
            if (h >= 0x81 && h <= 0xFE && l >= 0x40 && l <= 0xFE && l != 0x7F) {
                return true;
            }
        }
        return false;
    }

    /** 是否含汉字（基本区）。 */
    public static boolean containsCjk(String s) {
        if (s == null) {
            return false;
        }
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c >= '\u4E00' && c <= '\u9FFF') {
                return true;
            }
        }
        return false;
    }

    /**
     * 截断到第一个 NUL。
     *
     * <p>文本帧用 NUL 表示结束，ID3v2.4 也用 NUL 分隔多个值。不去掉的话标签值末尾会挂
     * 一个不可见字符，{@code trim()} 拿它没办法 —— 后果是「看着一样但比较不相等」，
     * 联网匹配全落空，文件名里还可能混进控制字符。
     */
    public static String stripNul(String s) {
        if (s == null) {
            return "";
        }
        int i = s.indexOf('\u0000');
        return i < 0 ? s : s.substring(0, i);
    }
}
