/// 运行日志：分级记录到文件，可一键导出。
///
/// 关键约束（不可放宽）：**日志里不得出现本机路径、身份与凭据**。
/// 所以写入前一律过 [sanitize]：绝对路径只留最后一段，其余抹掉。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 日志级别。
enum LogLevel { debug, info, warn, error }

/// 运行日志。
abstract final class Log {
  /// 日志保留天数。
  static const int keepDays = 7;

  /// 单文件上限（超过就轮换）。
  static const int maxBytes = 512 * 1024;

  static File? _file;
  static bool _ready = false;

  /// 准备日志目录（启动时调一次；失败就静默不记日志）。
  static Future<void> init() async {
    if (_ready) return;
    try {
      final Directory base = await getApplicationSupportDirectory();
      final Directory dir = Directory('${base.path}/logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _file = File('${dir.path}/app.log');
      _ready = true;
      _rotateIfNeeded();
      _purgeOld();
    } catch (_) {
      _ready = false;
    }
  }

  /// 记一条日志。
  static void write(LogLevel level, String message,
      {Object? error, StackTrace? stack}) {
    if (!_ready || _file == null) return;
    try {
      final StringBuffer sb = StringBuffer();
      sb.write(_stamp());
      sb.write(' [${_tag(level)}] ');
      sb.write(sanitize(message));
      if (error != null) {
        sb.write(' · 错误：');
        sb.write(sanitize('$error'));
      }
      if (stack != null) {
        // 堆栈里全是本机路径与行号，只留前几帧的函数名
        sb.write('\n    ${sanitize(_shortStack(stack))}');
      }
      sb.write('\n');
      _file!.writeAsStringSync(sb.toString(), mode: FileMode.append, flush: true);
    } catch (_) {
      // 记日志失败不能影响主流程
    }
  }

  /// 便捷入口。
  static void info(String message) => write(LogLevel.info, message);
  static void warn(String message) => write(LogLevel.warn, message);
  static void error(String message, {Object? e, StackTrace? stack}) =>
      write(LogLevel.error, message, error: e, stack: stack);

  /// 读最近的日志（给界面看）。
  static Future<String> readTail({int maxBytes = 64 * 1024}) async {
    await init();
    final File? f = _file;
    if (f == null || !f.existsSync()) return '';
    try {
      final int len = f.lengthSync();
      final int from = len > maxBytes ? len - maxBytes : 0;
      final RandomAccessFile raf = await f.open();
      try {
        await raf.setPosition(from);
        final int remain = await raf.length();
        final Uint8List bytes = await raf.read(remain);
        return sanitize(utf8.decode(bytes, allowMalformed: true));
      } finally {
        await raf.close();
      }
    } catch (_) {
      return '';
    }
  }

  /// 导出日志：复制一份到应用支持目录根下，返回文件路径。
  ///
  /// 导出的是**清理过**的文本 —— 不含本机路径与身份信息。
  static Future<String?> export() async {
    await init();
    final File? f = _file;
    if (f == null) return null;
    try {
      final Directory base = await getApplicationSupportDirectory();
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final File out = File('${base.path}/musicorganizer-log-$stamp.txt');
      await out.writeAsString(sanitize(await f.readAsString()));
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// 导出用的全文（已脱敏）；安卓上交给系统「保存到…」用。
  static Future<String> exportText({int maxBytes = 512 * 1024}) async {
    await init();
    final File? f = _file;
    if (f == null) return '';
    try {
      final String raw = await f.readAsString();
      final String cut =
          raw.length > maxBytes ? raw.substring(raw.length - maxBytes) : raw;
      return sanitize(cut);
    } catch (_) {
      return '';
    }
  }

  /// 清空日志。
  static Future<void> clear() async {
    await init();
    try {
      _file?.writeAsStringSync('');
    } catch (_) {
      // 忽略
    }
  }

  /// 去掉本机路径与常见凭据片段。
  ///
  /// 绝对路径只保留最后一段；`key=value` 形态的凭据只留键名。
  static String sanitize(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    String s = raw;
    // 形如 C:\Users\xxx\... 或 /home/xxx/... 的绝对路径 → 只留最后一段
    s = s.replaceAllMapped(RegExp(r'''[A-Za-z]:[\\/][^\s"'<>|]*'''), _keepTail);
    s = s.replaceAllMapped(RegExp(r'''/(?:[^\s"'<>|/]+/)+'''), _keepTail);
    // 凭据：token / password / secret / key = 值
    s = s.replaceAll(
        RegExp(r'\b(token|password|passwd|secret|api[_-]?key|access[_-]?key)\s*[=:]\s*\S+',
            caseSensitive: false),
        r'$1=***');
    return s;
  }

  static String _keepTail(Match m) {
    final String text = m.group(0) ?? '';
    final List<String> parts = text.split(RegExp(r'[\\/]'));
    final String last = parts.isEmpty ? '' : parts.last;
    return last.isEmpty ? '***' : '…/$last';
  }

  static String _shortStack(StackTrace stack) {
    final List<String> lines = stack
        .toString()
        .split('\n')
        .where((String l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    return lines.take(6).map((String l) {
      final String t = l.trim();
      // 只留「函数名(文件:行)」里的函数名
      final int paren = t.indexOf('(');
      final String fn = paren > 0 ? t.substring(0, paren) : t;
      final int at = fn.indexOf(' ');
      return at > 0 ? fn.substring(0, at) : fn;
    }).join(' / ');
  }

  static void _rotateIfNeeded() {
    final File? f = _file;
    if (f == null || !f.existsSync()) return;
    try {
      if (f.lengthSync() < maxBytes) return;
      final File old = File('${f.path}.1');
      if (old.existsSync()) old.deleteSync();
      f.renameSync(old.path);
      _file = File(f.path);
    } catch (_) {
      // 忽略
    }
  }

  static void _purgeOld() {
    final File? f = _file;
    if (f == null) return;
    try {
      final File old = File('${f.path}.1');
      if (!old.existsSync()) return;
      final DateTime cutoff = DateTime.now().subtract(Duration(days: keepDays));
      if (old.lastModifiedSync().isBefore(cutoff)) old.deleteSync();
    } catch (_) {
      // 忽略
    }
  }

  static String _stamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${two(now.millisecond ~/ 10)}';
  }

  static String _tag(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 'D';
      case LogLevel.info:
        return 'I';
      case LogLevel.warn:
        return 'W';
      case LogLevel.error:
        return 'E';
    }
  }
}
