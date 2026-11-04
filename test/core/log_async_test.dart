import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/log/log.dart';

/// 日志异步写盘（0.2.65）：info 入队、error 立即落盘、flush 保证读到最新。
void main() {
  late Directory base;

  setUp(() async {
    Log.resetForTest();
    base = await Directory.systemTemp.createTemp('mo_log_');
    Log.dirOverride = () async => base;
  });

  tearDown(() async {
    Log.resetForTest();
    try {
      await base.delete(recursive: true);
    } catch (_) {
      // 忽略
    }
  });

  Future<File> logFile() async {
    await Log.init();
    return File('${base.path}/logs/app.log');
  }

  Future<String> readAll() async {
    final File f = await logFile();
    if (!f.existsSync()) return '';
    return f.readAsStringSync();
  }

  test('info 入队后不会立即落盘，flush 后落盘', () async {
    await Log.init();
    Log.info('第一行');
    Log.info('第二行');

    // 还没 flush：文件不存在（info 只在攒满 32 条或定时器触发时才写）
    final File f = await logFile();
    expect(f.existsSync(), isFalse, reason: 'info 不应立即写盘');

    await Log.flush();
    final String text = await readAll();
    expect(text, contains('第一行'));
    expect(text, contains('第二行'));
  });

  test('error 立即落盘，不用等 flush', () async {
    await Log.init();
    Log.error('出错了');

    final String text = await readAll();
    expect(text, contains('出错了'));
    expect(text, contains('[E]'), reason: '错误日志带 E 标记');
  });

  test('readTail 会先把队列写进去再读', () async {
    await Log.init();
    Log.info('还没写盘的一行');
    final String tail = await Log.readTail();
    expect(tail, contains('还没写盘的一行'));
  });

  test('clear 清空后文件为空', () async {
    await Log.init();
    Log.error('要清掉的一行');
    expect(await readAll(), contains('要清掉的一行'));

    await Log.clear();
    expect(await readAll(), '');
  });

  test('批量写：32 条 info 触发一次落盘', () async {
    await Log.init();
    for (int i = 0; i < 32; i++) {
      Log.info('批量第 $i 行');
    }
    // 第 32 条触发异步 flush，等一下让它写完
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final String text = await readAll();
    expect(text, contains('批量第 31 行'));
  });
}
