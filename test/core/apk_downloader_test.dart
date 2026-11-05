import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/update/apk_downloader.dart';
import 'package:musicorganizer/core/update/sha256.dart';

/// 一个最小的本地 HTTP 服务，可以模拟「支持/不支持断点续传」和跳转。
class _FakeServer {
  _FakeServer._(this._server, this._body);

  final HttpServer _server;
  final Uint8List _body;

  /// 收到的 Range 请求头（按顺序记录，测试断言用）。
  final List<String> rangeHeaders = <String>[];

  /// 每个请求路径 → 该请求的 Range（跳转后那一条用它断言）。
  final Map<String, String> rangeByPath = <String, String>{};

  /// 为 true 时无视 Range，永远回 200 + 完整内容（模拟 Gitee CDN）。
  bool ignoreRange = false;

  /// 为 true 时第一次请求回 302 到 /real，用来测「手动跟跳转」。
  bool redirectOnce = true;

  int _hits = 0;

  int get port => _server.port;

  static Future<_FakeServer> start(Uint8List body) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _FakeServer fake = _FakeServer._(server, body);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    _hits++;
    if (redirectOnce && _hits == 1 && req.uri.path == '/apk') {
      // 模拟 Gitee 的两跳：先 302 到真实地址
      req.response.statusCode = HttpStatus.found;
      req.response.headers.set(
          HttpHeaders.locationHeader, '/real');
      await req.response.close();
      return;
    }
    final String? range = req.headers.value(HttpHeaders.rangeHeader);
    rangeHeaders.add(range ?? '');
    rangeByPath[req.uri.path] = range ?? '';
    print('HIT path= hits= range=');
    if (range != null && !ignoreRange) {
      final int from =
          int.tryParse(RegExp(r'bytes=(\d+)-').firstMatch(range)?.group(1) ?? '0') ?? 0;
      final List<int> rest = _body.sublist(from);
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.contentLength = rest.length;
      req.response.add(rest);
      await req.response.close();
      return;
    }
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentLength = _body.length;
    req.response.add(_body);
    await req.response.close();
  }
}

Uint8List _payload(int n) =>
    Uint8List.fromList(List<int>.generate(n, (int i) => i % 251));

void main() {
  group('ApkDownloader', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mo_apk_');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    ApkDownloader mk() => ApkDownloader(
          openConnection: openHttpConnection,
          now: (Duration d) => Future<void>.value(), // 测试里不退避等待
        );

    test('完整下载并通过 SHA256 校验', () async {
      final Uint8List body = _payload(300 * 1024);
      final _FakeServer srv = await _FakeServer.start(body);
      addTearDown(srv.close);
      final File target = File('${dir.path}/a.apk');

      final ApkDownloadResult r = await mk().download(
        url: 'http://127.0.0.1:${srv.port}/apk',
        target: target,
        expectedSha256: sha256Hex(body),
        expectedSize: body.length,
      );
      expect(r.ok, isTrue, reason: r.error);
      expect(await target.length(), body.length);
      expect(await target.readAsBytes(), body);
    });

    test('跳转后仍然带 Range（手动跟 302，不能丢头）', () async {
      final Uint8List body = _payload(200 * 1024);
      final _FakeServer srv = await _FakeServer.start(body);
      addTearDown(srv.close);
      final File target = File('${dir.path}/b.apk');
      // 先造一个半包，逼出 Range 请求
      await target.writeAsBytes(body.sublist(0, 100 * 1024));

      final ApkDownloadResult r = await mk().download(
        url: 'http://127.0.0.1:${srv.port}/apk',
        target: target,
        expectedSha256: sha256Hex(body),
        expectedSize: body.length,
      );
      expect(r.ok, isTrue, reason: r.error);
      // 关键断言：**跳转之后**那一跳（/real）也必须带 Range。
      // 只断言「某处出现过 Range」是不够的——跳转前那次带了，跳转后丢了
      // 照样能骗过测试，而实际续传已经失效。
      expect(srv.rangeByPath['/real'], startsWith('bytes='),
          reason: '跨 302 后 Range 必须还在，否则断点续传失效');
      expect(await target.readAsBytes(), body);
    });
    test('源不支持续传（Range 回 200）时清空重下，最终文件仍完整', () async {
      final Uint8List body = _payload(150 * 1024);
      final _FakeServer srv = await _FakeServer.start(body);
      addTearDown(srv.close);
      srv.ignoreRange = true;
      final File target = File('${dir.path}/c.apk');
      await target.writeAsBytes(body.sublist(0, 60 * 1024));

      final ApkDownloadResult r = await mk().download(
        url: 'http://127.0.0.1:${srv.port}/apk',
        target: target,
        expectedSha256: sha256Hex(body),
        expectedSize: body.length,
      );
      expect(r.ok, isTrue, reason: r.error);
      expect(await target.readAsBytes(), body,
          reason: '半包内容不能粘在新文件前面');
    });

    test('SHA256 不符：删掉文件并报错，不把坏包交给安装器', () async {
      final Uint8List body = _payload(64 * 1024);
      final _FakeServer srv = await _FakeServer.start(body);
      addTearDown(srv.close);
      final File target = File('${dir.path}/d.apk');

      final ApkDownloadResult r = await mk().download(
        url: 'http://127.0.0.1:${srv.port}/apk',
        target: target,
        expectedSha256: 'a' * 64, // 故意不符
        expectedSize: body.length,
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('校验不通过'));
      expect(await target.exists(), isFalse);
    });

    test('取消后不再继续，已下部分保留（下次可续传）', () async {
      final Uint8List body = _payload(400 * 1024);
      final _FakeServer srv = await _FakeServer.start(body);
      addTearDown(srv.close);
      final File target = File('${dir.path}/e.apk');
      bool stop = false;

      final ApkDownloadResult r = await mk().download(
        url: 'http://127.0.0.1:${srv.port}/apk',
        target: target,
        expectedSize: body.length,
        cancel: () => stop,
        onProgress: (ApkProgress p) {
          if (p.received > 64 * 1024) stop = true;
        },
      );
      expect(r.cancelled, isTrue);
      expect(r.ok, isFalse);
    });

    test('进度回调单调不减，百分比不超过 100', () async {
      final Uint8List body = _payload(500 * 1024);
      final _FakeServer srv = await _FakeServer.start(body);
      addTearDown(srv.close);
      final File target = File('${dir.path}/f.apk');
      final List<int> seen = <int>[];

      final ApkDownloadResult r = await mk().download(
        url: 'http://127.0.0.1:${srv.port}/apk',
        target: target,
        expectedSize: body.length,
        onProgress: (ApkProgress p) => seen.add(p.percent),
      );
      expect(r.ok, isTrue, reason: r.error);
      for (int i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]),
            reason: '进度不能往回跳，否则用户看到的是反复横跳');
      }
      expect(seen.every((int p) => p >= -1 && p <= 100), isTrue);
    });

    test('已有完整且校验通过的文件：直接复用，不重下', () async {
      final Uint8List body = _payload(32 * 1024);
      final _FakeServer srv = await _FakeServer.start(body);
      addTearDown(srv.close);
      final File target = File('${dir.path}/g.apk');
      await target.writeAsBytes(body);

      final ApkDownloadResult r = await mk().download(
        url: 'http://127.0.0.1:${srv.port}/apk',
        target: target,
        expectedSha256: sha256Hex(body),
        expectedSize: body.length,
      );
      expect(r.ok, isTrue);
      expect(srv.rangeHeaders, isEmpty, reason: '文件已在本地，不该再发请求');
    });
  });
}
