/// 运行日志：分级记录到文件，可一键导出。
///
/// 关键约束（不可放宽）：**日志里不得出现本机路径、身份与凭据**。
/// 所以写入前一律过 [sanitize]：绝对路径只留最后一段，其余抹掉。
///
/// 0.2.65：写盘改异步。原来每条日志都 `writeAsStringSync(flush: true)`，
/// 同步强制刷盘——现在调用点虽不多，但都是错误路径；一旦将来往热路径加
/// 日志，这一下就会变成卡顿源。现在 [write] 只入内存队列，后台定时器
/// 每 500ms（或攒满 32 条）批量写一次；**error 级别立即 flush**，
/// 崩溃日志不会因为还没到定时器就丢。
library;

import 'dart:async';
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

  /// 攒满多少条强制 flush 一次。
  static const int _batchSize = 32;

  /// 定时 flush 间隔。
  static const Duration _flushInterval = Duration(milliseconds: 500);

  static File? _file;
  static bool _ready = false;

  /// 单测注入：日志目录（不传时用应用支持目录）。测试专用，勿在生产路径设置。
  static Future<Directory?> Function()? dirOverride;

  /// 待写队列：还没落盘的完整日志行。
  static final List<String> _pending = <String>[];

  /// 定时 flush 的计时器。
  static Timer? _timer;

  /// 正在写盘（防止定时器与 error 立即 flush 并发写同一文件）。
  static bool _writing = false;

  /// 写盘完成但期间又有人入队：需要再补一轮。
  static bool _dirty = false;

  /// 准备日志目录（启动时调一次；失败就静默不记日志）。
  static Future<void> init() async {
    if (_ready) return;
    try {
      final Directory? base = dirOverride != null
          ? await dirOverride!()
          : await getApplicationSupportDirectory();
      if (base == null) {
        _ready = false;
        return;
      }
      final Directory dir = Directory('${base.path}/logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _file = File('${dir.path}/app.log');
      _ready = true;
      _rotateIfNeeded();
      _purgeOld();
      _timer ??= Timer.periodic(_flushInterval, (_) => flush());
    } catch (_) {
      _ready = false;
    }
  }

  /// 单测之间复位：清状态、停定时器。测试专用，勿在生产路径调用。
  static void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _writing = false;
    _dirty = false;
    _file = null;
    _ready = false;
    dirOverride = null;
  }

  /// 记一条日志。
  ///
  /// info / warn / debug 入队，由定时器批量异步写；**error 同步写盘**——
  /// 崩溃日志不能赌「进程在异步 flush 完成前还活着」，必须当场落盘。
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
      if (level == LogLevel.error) {
        // 错误路径：先把队列里的历史写进去，再写本条，保证顺序
        final File? f = _file;
        if (f != null) {
          if (_pending.isNotEmpty) {
            final String batch = _pending.join();
            _pending.clear();
            f.writeAsStringSync(batch, mode: FileMode.append, flush: true);
          }
          f.writeAsStringSync(sb.toString(), mode: FileMode.append, flush: true);
        }
        return;
      }
      _pending.add(sb.toString());
      if (_pending.length >= _batchSize) {
        // 攒满一批：异步写，不阻塞当前调用
        unawaited(flush());
      }
    } catch (_) {
      // 记日志失败不能影响主流程
    }
  }

  /// 把队列里的日志写进文件（异步执行；幂等，重复调用安全）。
  ///
  /// 不 await 也能用——下次 flush 会接着写剩下的。需要「保证这次写完了」
  /// 的调用方（导出 / 清空前）请 await。
  static Future<void> flush() async {
    if (_pending.isEmpty) return;
    if (_writing) {
      _dirty = true;
      return;
    }
    _writing = true;
    try {
      final File? f = _file;
      if (f == null) {
        _pending.clear();
        return;
      }
      final String batch = _pending.join();
      _pending.clear();
      await f.writeAsString(batch, mode: FileMode.append, flush: true);
    } catch (_) {
      // 写失败不阻塞主流程；已清掉的队列不恢复（宁可少记，不能卡）
    } finally {
      _writing = false;
      if (_dirty) {
        _dirty = false;
        unawaited(flush());
      }
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
    await flush(); // 先把队列里的写进去，界面才看得到最新
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
    await flush();
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
    await flush();
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
    await flush();
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
    // URI 先换成占位符：否则 content:// 里的 `t:/`、file:// 里的 `e:/`
    // 会被下面的 Windows 盘符正则当成路径再削一次。
    const String contentMark = '\u0001MO_CONTENT\u0001';
    const String fileMark = '\u0001MO_FILE\u0001';
    s = s.replaceAll(RegExp(r'content://[^\s"<>|]+'), contentMark);
    s = s.replaceAll(RegExp(r'file://[^\s"<>|]+'), fileMark);
    // UNC：\\server\share\... → 只留最后一段
    s = s.replaceAllMapped(RegExp(r'\\\\[^\s"<>|]+'), _keepTail);
    // 形如 C:\Users\xxx\... 或 /home/xxx/... 的绝对路径 → 只留最后一段
    s = s.replaceAllMapped(RegExp(r'''[A-Za-z]:[\\/][^\s"'<>|]*'''), _keepTail);
    s = s.replaceAllMapped(RegExp(r'''/(?:[^\s"'<>|/]+/)+'''), _keepTail);
    // 凭据：token / password / secret / key = 值（replaceAll 不支持 $1，必须用 Mapped）
    s = s.replaceAllMapped(
        RegExp(r'\b(token|password|passwd|secret|api[_-]?key|access[_-]?key)\s*[=:]\s*\S+',
            caseSensitive: false),
        (Match m) => '${m.group(1)}=***');
    s = s.replaceAll(contentMark, 'content://***');
    s = s.replaceAll(fileMark, 'file://***');
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
