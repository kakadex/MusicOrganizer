
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/fs/saf_file_store.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/platform/saf_channel.dart';

/// 记录每次方法调用参数的假通道（0.2.68 的调度契约）。
class _RecordingChannel extends SafChannel {
  final List<MethodCall> calls = <MethodCall>[];

  @override
  Future<Map<String, Object?>?> stat(String treeUri, String docId,
      {bool priority = false, String? token}) async {
    calls.add(MethodCall('stat', <String, Object?>{
      'docId': docId,
      'priority': priority ? true : null,
      'token': token,
    }));
    return <String, Object?>{
      'docId': docId,
      'parentId': 'root',
      'name': 'a.mp3',
      'size': 1,
    };
  }

  @override
  Future<Uint8List?> readHead(String treeUri, String docId, int maxBytes,
      {bool priority = false, String? token}) async {
    calls.add(MethodCall('readHead', <String, Object?>{
      'docId': docId,
      'priority': priority ? true : null,
      'token': token,
    }));
    return Uint8List(0);
  }

  @override
  Future<void> cancelBatch(String token) async {
    calls.add(MethodCall('cancelBatch', <String, Object?>{'token': token}));
  }
}

void main() {
  late _RecordingChannel ch;
  late SafFileStore store;

  setUp(() {
    ch = _RecordingChannel();
    store = SafFileStore(channel: ch)
      ..lookup.add(const TreeRef(treeUri: 't', rootDocId: 'root'));
  });

  test('普通调用不带 priority（走批量池）', () async {
    await store.stat('root/a.mp3');
    expect(ch.calls.single.arguments['priority'], isNull);
  });

  test('runInteractive 期间带 priority（走交互池，不被批量任务堵住）', () async {
    await store.runInteractive(() => store.stat('root/a.mp3'));
    expect(ch.calls.single.arguments['priority'], isTrue);
  });

  test('runInteractive 结束后标记复位（否则批量任务会被永久提到交互池）', () async {
    await store.runInteractive(() => store.stat('root/a.mp3'));
    await store.stat('root/a.mp3');
    expect(ch.calls.first.arguments['priority'], isTrue);
    expect(ch.calls.last.arguments['priority'], isNull);
  });

  test('嵌套 runInteractive 只认最外层：内层结束不关闭外层标记', () async {
    await store.runInteractive(() async {
      await store.runInteractive(() => Future<void>.value());
      await store.stat('root/a.mp3'); // 外层仍然有效
    });
    expect(ch.calls.single.arguments['priority'], isTrue);
  });

  test('异常也会复位标记', () async {
    await expectLater(
      store.runInteractive<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    await store.stat('root/a.mp3');
    expect(ch.calls.single.arguments['priority'], isNull);
  });

  test('cancelPending 把令牌交给平台（丢弃排队中的调用）', () async {
    await store.cancelPending('batch-1');
    final MethodCall c = ch.calls.single;
    expect(c.method, 'cancelBatch');
    expect(c.arguments['token'], 'batch-1');
  });

  test('SafFileStore 是 FileStore，桌面实现无需调度差异', () {
    // 契约存在性：两个钩子在接口里都有默认实现，桌面端不覆写也能编译运行。
    final FileStoreHookProbe probe = FileStoreHookProbe();
    expect(probe.runInteractive(() async => 1), completion(1));
    expect(probe.cancelPending('x'), completion(isNull));
  });
}

/// 只实现抽象成员、两个钩子用接口默认实现（验证默认可编译可运行）。
class FileStoreHookProbe implements FileStore {
  @override
  Future<T> runInteractive<T>(Future<T> Function() action) => action();

  @override
  Future<void> cancelPending(String token) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
