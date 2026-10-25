/// 极简 JSON（对象 / 数组 / 字符串 / 数字 / true / false / null）——
/// 移植自旧 core/Json.java，零第三方依赖。
///
/// 约定：解析出的数字统一是 double，调用方自行转 int / bool；
/// 字符串转义时非 ASCII 一律写成 \uXXXX（备份文件在任何编辑器里都不乱码）。
library;

/// JSON 编解码工具（纯 Dart）。
abstract final class Json {
  /// 字符串转义：非 ASCII 写成 Unicode 转义序列。
  static String quote(String? s) {
    if (s == null) return 'null';
    final StringBuffer sb = StringBuffer()..write('"');
    for (final int c in s.codeUnits) {
      if (c == 0x22) {
        sb.write('\\"');
      } else if (c == 0x5C) {
        sb.write('\\\\');
      } else if (c == 0x0A) {
        sb.write('\\n');
      } else if (c == 0x0D) {
        sb.write('\\r');
      } else if (c == 0x09) {
        sb.write('\\t');
      } else if (c < 0x20 || c > 0x7E) {
        sb.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
      } else {
        sb.writeCharCode(c);
      }
    }
    sb.write('"');
    return sb.toString();
  }

  /// 值转 JSON（bool / num / String；其余按字符串处理）。
  static String value(Object? v) {
    if (v == null) return 'null';
    if (v is bool) return v ? 'true' : 'false';
    if (v is num) {
      final double d = v.toDouble();
      if (d == d.roundToDouble() && !d.isInfinite) {
        return v.toInt().toString();
      }
      return d.toString();
    }
    return quote(v.toString());
  }

  /// 解析 JSON 文本；结构不合法时抛 [FormatException]。
  static Object? parse(String text) {
    final _Parser p = _Parser(text);
    p._skipWs();
    final Object? v = p._value();
    p._skipWs();
    if (p._pos < p._src.length) {
      throw FormatException('多余内容在第 ${p._pos + 1} 个字符');
    }
    return v;
  }

  /// 解析失败时返回 null（不想处理异常的场合用）。
  static Object? parseOrNull(String text) {
    try {
      return parse(text);
    } catch (_) {
      return null;
    }
  }
}

class _Parser {
  _Parser(String? src) : _src = src ?? '';

  final String _src;
  int _pos = 0;

  Object? _value() {
    if (_pos >= _src.length) throw const FormatException('意外结束');
    final String c = _src[_pos];
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == '"') return _string();
    if (_src.startsWith('true', _pos)) {
      _pos += 4;
      return true;
    }
    if (_src.startsWith('false', _pos)) {
      _pos += 5;
      return false;
    }
    if (_src.startsWith('null', _pos)) {
      _pos += 4;
      return null;
    }
    return _number();
  }

  Map<String, Object?> _object() {
    final Map<String, Object?> m = <String, Object?>{};
    _pos++; // {
    _skipWs();
    if (_pos < _src.length && _src[_pos] == '}') {
      _pos++;
      return m;
    }
    while (true) {
      _skipWs();
      if (_pos >= _src.length || _src[_pos] != '"') {
        throw FormatException('第 ${_pos + 1} 个字符处缺少键名');
      }
      final String key = _string();
      _skipWs();
      _expect(':');
      _skipWs();
      m[key] = _value();
      _skipWs();
      if (_pos >= _src.length) throw const FormatException('对象没有闭合');
      final String c = _src[_pos++];
      if (c == '}') return m;
      if (c != ',') throw FormatException('第 $_pos 个字符处应为 , 或 }');
    }
  }

  List<Object?> _array() {
    final List<Object?> list = <Object?>[];
    _pos++; // [
    _skipWs();
    if (_pos < _src.length && _src[_pos] == ']') {
      _pos++;
      return list;
    }
    while (true) {
      _skipWs();
      list.add(_value());
      _skipWs();
      if (_pos >= _src.length) throw const FormatException('数组没有闭合');
      final String c = _src[_pos++];
      if (c == ']') return list;
      if (c != ',') throw FormatException('第 $_pos 个字符处应为 , 或 ]');
    }
  }

  String _string() {
    _pos++; // 开引号
    final StringBuffer sb = StringBuffer();
    while (_pos < _src.length) {
      final int c = _src.codeUnitAt(_pos++);
      if (c == 0x22) return sb.toString();
      if (c != 0x5C) {
        sb.writeCharCode(c);
        continue;
      }
      if (_pos >= _src.length) break;
      final int e = _src.codeUnitAt(_pos++);
      if (e == 0x6E) {
        sb.write('\n');
      } else if (e == 0x72) {
        sb.write('\r');
      } else if (e == 0x74) {
        sb.write('\t');
      } else if (e == 0x62) {
        sb.write('\b');
      } else if (e == 0x66) {
        sb.write('\f');
      } else if (e == 0x75) {
        if (_pos + 4 > _src.length) throw const FormatException('\\u 转义不完整');
        sb.writeCharCode(int.parse(_src.substring(_pos, _pos + 4), radix: 16));
        _pos += 4;
      } else {
        sb.writeCharCode(e);
      }
    }
    throw const FormatException('字符串没有闭合');
  }

  double _number() {
    final int start = _pos;
    while (_pos < _src.length) {
      final int c = _src.codeUnitAt(_pos);
      if ((c >= 0x30 && c <= 0x39) ||
          c == 0x2D ||
          c == 0x2B ||
          c == 0x2E ||
          c == 0x65 ||
          c == 0x45) {
        _pos++;
      } else {
        break;
      }
    }
    if (start == _pos) {
      throw FormatException('第 ${_pos + 1} 个字符处不是合法值');
    }
    final String sub = _src.substring(start, _pos);
    final double? v = double.tryParse(sub);
    if (v == null) throw FormatException('数字格式错误：$sub');
    return v;
  }

  void _expect(String c) {
    if (_pos >= _src.length || _src[_pos] != c) {
      throw FormatException('第 ${_pos + 1} 个字符处应为 $c');
    }
    _pos++;
  }

  void _skipWs() {
    while (_pos < _src.length) {
      final int c = _src.codeUnitAt(_pos);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        _pos++;
      } else {
        break;
      }
    }
  }
}
