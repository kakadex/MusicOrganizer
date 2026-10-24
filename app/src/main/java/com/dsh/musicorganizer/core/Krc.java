package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.List;
import java.util.zip.DataFormatException;
import java.util.zip.Deflater;
import java.util.zip.Inflater;

/**
 * 酷狗 KRC 歌词：解密 + 转成增强型 LRC（v0.1.41）。
 *
 * <p>KRC 是酷狗的逐字歌词格式，内容形如：
 * <pre>
 * [id:$00000000]
 * [ar:周杰伦]
 * [ti:晴天]
 * [0,1000]&lt;0,300,0&gt;故&lt;300,300,0&gt;事&lt;600,400,0&gt;的&lt;0,900,0&gt;
 * </pre>
 * 每行以 {@code [行开始毫秒,行时长]} 开头，后面是逐字三元组 {@code <字开始,时长,0>字}。
 *
 * <p>服务器下发的 {@code fmt=krc} 内容是加密的：{@code base64} 解码后是
 * {@code "krc1"} + 用 **16 字节**密钥 XOR 过的 zlib 流。本类按这个公开格式实现：
 * <ol>
 *   <li>去掉前 4 字节 {@code krc1}；</li>
 *   <li>余下字节与 16 字节密钥循环异或（密钥见 {@link #KEY} 的注释，8 字节版本是错的）；</li>
 *   <li>{@code Inflater} 解压得到上面的纯文本 KRC。</li>
 * </ol>
 *
 * <p><b>2026-10-23 已用真实线上样本验证通过</b>（取 LDDC 的密钥对照后一次解开）。
 * v0.1.41 曾用错误的 8 字节密钥，异或后头两字节碰巧也是 {@code 78 9C}，
 * 但流从第 4 字节起错位，inflate 报 {@code invalid code lengths}。
 * 调用方仍应允许降级：解不出来就改用 {@code fmt=lrc} 的明文歌词
 * （见 {@code net.LyricSources.kugou}）。
 *
 * <p>纯 Java（自带 base64 解码，不依赖 {@code android.util.Base64}，也不要求 API 26），
 * 可在桌面 JVM 回归。
 */
public final class Krc {

    /**
     * XOR 密钥，16 字节，即 ASCII {@code "@Gaw^2tGQ61-"} + {@code CE D2 6E 69}（"哪" + "ni"）。
     *
     * <p><b>别改成 8 字节版本</b>：网上流传的 {@code 40 47 61 38 3B 39 3B 39} 是错的。
     * 它与正确密钥只有前 3 个字节相同，所以解出来**头两字节恰好仍是 {@code 78 9C}**
     * （zlib 魔数），后面的流从第 4 字节起整体错位，inflate 会报
     * {@code invalid code lengths} —— v0.1.41 就是这么被误导的。
     * 正确值取自 LDDC（GPL-3.0）的 {@code KRC_KEY = b"@Gaw^2tGQ61-\xce\xd2ni"}。
     */
    private static final byte[] KEY = new byte[]{
            0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
            0x51, 0x36, 0x31, 0x2D, (byte) 0xCE, (byte) 0xD2, 0x6E, 0x69
    };

    private static final String MAGIC = "krc1";

    private Krc() {
    }

    /** 是否是 KRC 内容的 base64（以 {@code a3Jj} / {@code a3JjMQ==} 开头，即 "krc"+...）。 */
    public static boolean looksEncoded(String base64) {
        if (base64 == null) {
            return false;
        }
        String s = base64.trim();
        return s.startsWith("a3Jj") || s.startsWith("krc1");
    }

    /**
     * 解密 + 解压。
     *
     * @param base64 服务端给的 {@code content} 字段
     * @return 纯文本 KRC；失败返回空串（调用方据此降级）
     */
    public static String decode(String base64) {
        byte[] body = decodeBase64(base64);
        if (body == null || body.length < 8) {
            return "";
        }
        int offset = 0;
        if (body.length > 4 && new String(body, 0, 4, java.nio.charset.StandardCharsets.US_ASCII)
                .equals(MAGIC)) {
            offset = 4;
        }
        byte[] payload = new byte[body.length - offset];
        for (int i = 0; i < payload.length; i++) {
            payload[i] = (byte) (body[offset + i] ^ KEY[i % KEY.length]);
        }
        String text = inflate(payload);
        if (text.isEmpty()) {
            // 有些样本在 zlib 流前多 4 字节长度：给一次容错机会
            if (payload.length > 8) {
                byte[] tail = new byte[payload.length - 4];
                System.arraycopy(payload, 4, tail, 0, tail.length);
                text = inflate(tail);
            }
        }
        return text;
    }

    /**
     * 纯文本 KRC → 增强型 LRC（逐字 {@code <mm:ss.xx>}）。
     *
     * <p>行首 {@code [ar:]}/{@code [ti:]}/{@code [id:]}/{@code [offset:]} 原样保留；
     * 逐字三元组的开始时间是**相对行首**的毫秒偏移，转成绝对时间时加上行开始时间。
     */
    public static String toEnhancedLrc(String krcText) {
        if (krcText == null || krcText.trim().isEmpty()) {
            return "";
        }
        StringBuilder out = new StringBuilder(krcText.length());
        String[] lines = krcText.replace("\r\n", "\n").replace('\r', '\n').split("\n");
        for (String raw : lines) {
            String line = raw.trim();
            if (line.isEmpty()) {
                continue;
            }
            if (line.startsWith("[") && !isTimedLine(line)) {
                // 元信息（[ar:]/[ti:]/[offset:]…）
                out.append(line).append('\n');
                continue;
            }
            String converted = convertLine(line);
            if (!converted.isEmpty()) {
                out.append(converted).append('\n');
            }
        }
        return out.toString().trim();
    }

    /** {@code [0,1000]&lt;0,300,0&gt;故…} → {@code [00:00.00]<00:00.00>故…}。 */
    private static String convertLine(String line) {
        int close = line.indexOf(']');
        if (close <= 0) {
            return "";
        }
        String head = line.substring(1, close);
        String[] parts = head.split(",");
        if (parts.length < 1) {
            return "";
        }
        long start;
        try {
            start = Long.parseLong(parts[0].trim());
        } catch (Exception e) {
            return "";
        }
        String body = line.substring(close + 1);
        StringBuilder sb = new StringBuilder(body.length() + 24);
        sb.append(stamp(start));
        int i = 0;
        boolean anyWord = false;
        while (i < body.length()) {
            char c = body.charAt(i);
            if (c != '<') {
                // 逐字之间偶尔夹着普通字符：直接跟在后面输出
                sb.append(c);
                i++;
                continue;
            }
            int end = body.indexOf('>', i);
            if (end < 0) {
                break;
            }
            String triple = body.substring(i + 1, end);
            String[] nums = triple.split(",");
            long wordStart = 0;
            boolean ok = false;
            if (nums.length >= 1) {
                try {
                    wordStart = Long.parseLong(nums[0].trim());
                    ok = true;
                } catch (Exception ignored) {
                    ok = false;
                }
            }
            String word = body.substring(end + 1);
            // 逐字文本一般在三元组后面紧跟，直到下一个 '<'
            int next = word.indexOf('<');
            String text = next >= 0 ? word.substring(0, next) : word;
            i = next >= 0 ? end + 1 + next : body.length();
            if (!ok) {
                sb.append(text);
                continue;
            }
            anyWord = true;
            sb.append(wordStamp(start + wordStart)).append(text);
        }
        // 没有逐字信息但有行时间：只输出行时间 + 文本
        if (!anyWord) {
            String plain = body.replaceAll("<[^>]*>", "");
            if (plain.trim().isEmpty()) {
                return "";
            }
            return stamp(start) + plain;
        }
        return sb.toString();
    }

    private static boolean isTimedLine(String line) {
        int close = line.indexOf(']');
        if (close <= 0) {
            return false;
        }
        String head = line.substring(1, close);
        return head.indexOf(',') > 0 && Character.isDigit(head.charAt(0));
    }

    private static String stamp(long ms) {
        long t = Math.max(0, ms);
        long totalSec = t / 1000;
        return String.format(java.util.Locale.US, "[%02d:%02d.%02d]",
                totalSec / 60, totalSec % 60, (t % 1000) / 10);
    }

    private static String wordStamp(long ms) {
        long t = Math.max(0, ms);
        long totalSec = t / 1000;
        return String.format(java.util.Locale.US, "<%02d:%02d.%02d>",
                totalSec / 60, totalSec % 60, (t % 1000) / 10);
    }

    // ------------------------------------------------------------------
    // 底层：base64 与 inflate（不依赖 android.util.Base64，minSdk 24 也能跑）
    // ------------------------------------------------------------------

    /** 宽容的 base64 解码：忽略空白、支持无填充与 urlsafe。失败返回 null。 */
    public static byte[] decodeBase64(String text) {
        if (text == null) {
            return null;
        }
        List<Byte> out = new ArrayList<Byte>(text.length());
        int buffer = 0;
        int bits = 0;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            int v;
            if (c >= 'A' && c <= 'Z') {
                v = c - 'A';
            } else if (c >= 'a' && c <= 'z') {
                v = c - 'a' + 26;
            } else if (c >= '0' && c <= '9') {
                v = c - '0' + 52;
            } else if (c == '+' || c == '-') {
                v = 62;
            } else if (c == '/' || c == '_') {
                v = 63;
            } else if (c == '=') {
                break;
            } else {
                continue; // 空白与换行
            }
            buffer = (buffer << 6) | v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                out.add(Byte.valueOf((byte) ((buffer >> bits) & 0xFF)));
            }
        }
        byte[] bytes = new byte[out.size()];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = out.get(i).byteValue();
        }
        return bytes;
    }

    private static String inflate(byte[] data) {
        if (data == null || data.length == 0) {
            return "";
        }
        Inflater inflater = new Inflater();
        try {
            inflater.setInput(data);
            byte[] buf = new byte[8192];
            StringBuilder sb = new StringBuilder(data.length * 2);
            while (!inflater.finished()) {
                int n = inflater.inflate(buf);
                if (n == 0) {
                    if (inflater.needsInput() || inflater.needsDictionary()) {
                        break;
                    }
                } else {
                    sb.append(new String(buf, 0, n, java.nio.charset.StandardCharsets.UTF_8));
                }
            }
            return sb.toString();
        } catch (DataFormatException e) {
            return "";
        } finally {
            inflater.end();
        }
    }

    /** 供测试与「万一要自己打包」用：zlib 压缩 + 加头 + XOR。 */
    public static String encodeForTest(String plain) {
        Deflater deflater = new Deflater();
        deflater.setInput(plain.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        deflater.finish();
        java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        while (!deflater.finished()) {
            int n = deflater.deflate(buf);
            bos.write(buf, 0, n);
        }
        deflater.end();
        byte[] z = bos.toByteArray();
        byte[] out = new byte[4 + z.length];
        out[0] = 'k';
        out[1] = 'r';
        out[2] = 'c';
        out[3] = '1';
        for (int i = 0; i < z.length; i++) {
            out[4 + i] = (byte) (z[i] ^ KEY[i % KEY.length]);
        }
        return encodeBase64(out);
    }

    private static String encodeBase64(byte[] data) {
        String table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        StringBuilder sb = new StringBuilder((data.length + 2) / 3 * 4);
        int i = 0;
        while (i + 2 < data.length) {
            int n = ((data[i] & 0xFF) << 16) | ((data[i + 1] & 0xFF) << 8) | (data[i + 2] & 0xFF);
            sb.append(table.charAt((n >> 18) & 63)).append(table.charAt((n >> 12) & 63))
                    .append(table.charAt((n >> 6) & 63)).append(table.charAt(n & 63));
            i += 3;
        }
        int left = data.length - i;
        if (left == 1) {
            int n = (data[i] & 0xFF) << 16;
            sb.append(table.charAt((n >> 18) & 63)).append(table.charAt((n >> 12) & 63))
                    .append("==");
        } else if (left == 2) {
            int n = ((data[i] & 0xFF) << 16) | ((data[i + 1] & 0xFF) << 8);
            sb.append(table.charAt((n >> 18) & 63)).append(table.charAt((n >> 12) & 63))
                    .append(table.charAt((n >> 6) & 63)).append('=');
        }
        return sb.toString();
    }
}
