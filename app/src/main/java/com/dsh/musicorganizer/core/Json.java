package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 极简 JSON（对象 / 数组 / 字符串 / 数字 / true / false / null）。
 *
 * <p>为什么不直接用 {@code org.json}：它是 Android 平台库，桌面 JVM 里没有，
 * 而本项目的核心逻辑（设置备份、批量任务记忆）都要能在纯 JVM 里跑离线回归。
 * 这里只需要「读写自己生成的那几种结构」，两百行足够，也不引入任何第三方依赖。
 *
 * <p>约定：解析出的数字统一是 {@link Double}，调用方自己转 int/bool。
 */
public final class Json {

    private Json() {
    }

    // ------------------------------------------------------------------
    // 写
    // ------------------------------------------------------------------

    /** 字符串转义：非 ASCII 一律写成 Unicode 转义序列，备份文件在任何编辑器里都不会乱码。 */
    public static String quote(String s) {
        if (s == null) {
            return "null";
        }
        StringBuilder sb = new StringBuilder(s.length() + 2);
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':
                    sb.append("\\\"");
                    break;
                case '\\':
                    sb.append("\\\\");
                    break;
                case '\n':
                    sb.append("\\n");
                    break;
                case '\r':
                    sb.append("\\r");
                    break;
                case '\t':
                    sb.append("\\t");
                    break;
                default:
                    if (c < 0x20 || c > 0x7e) {
                        sb.append(String.format("\\u%04x", Integer.valueOf(c)));
                    } else {
                        sb.append(c);
                    }
            }
        }
        sb.append('"');
        return sb.toString();
    }

    /** 值转 JSON（Boolean / Number / String；其余按字符串处理）。 */
    public static String value(Object v) {
        if (v == null) {
            return "null";
        }
        if (v instanceof Boolean) {
            return ((Boolean) v).booleanValue() ? "true" : "false";
        }
        if (v instanceof Number) {
            double d = ((Number) v).doubleValue();
            if (d == Math.rint(d) && !Double.isInfinite(d)) {
                return String.valueOf(((Number) v).longValue());
            }
            return String.valueOf(d);
        }
        return quote(String.valueOf(v));
    }

    // ------------------------------------------------------------------
    // 读
    // ------------------------------------------------------------------

    /** 解析 JSON 文本；结构不合法时抛 {@link IllegalArgumentException}。 */
    public static Object parse(String text) {
        Parser p = new Parser(text);
        p.skipWs();
        Object v = p.value();
        p.skipWs();
        if (p.pos < p.src.length()) {
            throw new IllegalArgumentException("多余内容在第 " + (p.pos + 1) + " 个字符");
        }
        return v;
    }

    /** 解析失败时返回 null（不想处理异常的场合用）。 */
    public static Object parseOrNull(String text) {
        try {
            return parse(text);
        } catch (RuntimeException e) {
            return null;
        }
    }

    private static final class Parser {
        private final String src;
        private int pos;

        Parser(String src) {
            this.src = src == null ? "" : src;
        }

        Object value() {
            if (pos >= src.length()) {
                throw new IllegalArgumentException("意外结束");
            }
            char c = src.charAt(pos);
            if (c == '{') {
                return object();
            }
            if (c == '[') {
                return array();
            }
            if (c == '"') {
                return string();
            }
            if (src.startsWith("true", pos)) {
                pos += 4;
                return Boolean.TRUE;
            }
            if (src.startsWith("false", pos)) {
                pos += 5;
                return Boolean.FALSE;
            }
            if (src.startsWith("null", pos)) {
                pos += 4;
                return null;
            }
            return number();
        }

        private Map<String, Object> object() {
            Map<String, Object> m = new LinkedHashMap<String, Object>();
            pos++; // {
            skipWs();
            if (pos < src.length() && src.charAt(pos) == '}') {
                pos++;
                return m;
            }
            while (true) {
                skipWs();
                if (pos >= src.length() || src.charAt(pos) != '"') {
                    throw new IllegalArgumentException("第 " + (pos + 1) + " 个字符处缺少键名");
                }
                String key = string();
                skipWs();
                expect(':');
                skipWs();
                m.put(key, value());
                skipWs();
                if (pos >= src.length()) {
                    throw new IllegalArgumentException("对象没有闭合");
                }
                char c = src.charAt(pos++);
                if (c == '}') {
                    return m;
                }
                if (c != ',') {
                    throw new IllegalArgumentException("第 " + pos + " 个字符处应为 , 或 }");
                }
            }
        }

        private List<Object> array() {
            List<Object> list = new ArrayList<Object>();
            pos++; // [
            skipWs();
            if (pos < src.length() && src.charAt(pos) == ']') {
                pos++;
                return list;
            }
            while (true) {
                skipWs();
                list.add(value());
                skipWs();
                if (pos >= src.length()) {
                    throw new IllegalArgumentException("数组没有闭合");
                }
                char c = src.charAt(pos++);
                if (c == ']') {
                    return list;
                }
                if (c != ',') {
                    throw new IllegalArgumentException("第 " + pos + " 个字符处应为 , 或 ]");
                }
            }
        }

        private String string() {
            pos++; // 开引号
            StringBuilder sb = new StringBuilder();
            while (pos < src.length()) {
                char c = src.charAt(pos++);
                if (c == '"') {
                    return sb.toString();
                }
                if (c != '\\') {
                    sb.append(c);
                    continue;
                }
                if (pos >= src.length()) {
                    break;
                }
                char e = src.charAt(pos++);
                switch (e) {
                    case 'n':
                        sb.append('\n');
                        break;
                    case 'r':
                        sb.append('\r');
                        break;
                    case 't':
                        sb.append('\t');
                        break;
                    case 'b':
                        sb.append('\b');
                        break;
                    case 'f':
                        sb.append('\f');
                        break;
                    case 'u':
                        if (pos + 4 > src.length()) {
                            throw new IllegalArgumentException("\\u 转义不完整");
                        }
                        sb.append((char) Integer.parseInt(src.substring(pos, pos + 4), 16));
                        pos += 4;
                        break;
                    default:
                        sb.append(e);
                }
            }
            throw new IllegalArgumentException("字符串没有闭合");
        }

        private Object number() {
            int start = pos;
            while (pos < src.length()) {
                char c = src.charAt(pos);
                if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'
                        || c == 'e' || c == 'E') {
                    pos++;
                } else {
                    break;
                }
            }
            if (start == pos) {
                throw new IllegalArgumentException("第 " + (pos + 1) + " 个字符处不是合法值");
            }
            try {
                return Double.valueOf(src.substring(start, pos));
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("数字格式错误：" + src.substring(start, pos));
            }
        }

        private void expect(char c) {
            if (pos >= src.length() || src.charAt(pos) != c) {
                throw new IllegalArgumentException("第 " + (pos + 1) + " 个字符处应为 " + c);
            }
            pos++;
        }

        private void skipWs() {
            while (pos < src.length()) {
                char c = src.charAt(pos);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                    pos++;
                } else {
                    break;
                }
            }
        }
    }
}
