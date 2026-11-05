/// 应用内更新：下载 APK（支持断点续传）+ SHA-256 校验 + 拉起安装（0.2.70）。
///
/// 纯 Dart，不依赖 flutter——方便单测。平台动作（下载目录、装包）通过
/// 注入的函数完成，测试里可以换成假的。
///
/// ## 为什么不用现成的 `Http.getBytes`
///
/// 那个是「整包读进内存」，19MB 的 APK 会占 19MB 峰值内存；而且它不管 302
/// 与 Range，做不到断点续传。
///
/// ## 两个来自加班记的实测结论（直接沿用，别重新踩）
///
/// 1. **不能依赖 HttpClient 自动跟 302**：跨主机跳转时 Dart 的 `HttpClient`
///    会不会保留自定义 Range 头不可靠（Dart 的实现与 JVM 不同，但同样
///    不属于我们可控范围）。这里**手动跟跳转**，每一跳都重新设 Range，
///    行为可预测。
/// 2. **有的源根本不支持续传**：Gitee 的 CDN 实测忽略 Range，照样回
///    200 + 完整长度。此时若把「已有字节数」当进度显示，用户会看到进度条
///    反复横跳。所以一旦发现「发了 Range 却回 200」，就记下该源不支持续传，
///    下次重试清空文件、进度归零重走——显示上永远是单调的 0→100。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'sha256.dart';

/// 下载进度。
class ApkProgress {
  const ApkProgress(this.received, this.total);

  /// 已下载字节数。
  final int received;

  /// 总字节数；0 表示服务器没给（界面显示「下载中…」）。
  final int total;

  /// 0..100；总量未知返回 -1。
  int get percent => total <= 0 ? -1 : (received * 100 ~/ total).clamp(0, 100);
}

/// 下载结果。
class ApkDownloadResult {
  const ApkDownloadResult({
    required this.ok,
    this.path = '',
    this.error = '',
    this.cancelled = false,
  });

  final bool ok;

  /// 下载好的 APK 绝对路径（ok 时有效）。
  final String path;

  /// 失败原因（用户可读的中文）。
  final String error;

  /// 用户主动取消。
  final bool cancelled;
}

/// 用真实 HttpClient 打开连接（应用内更新用）。
///
/// 超时给得比较宽松：切到别的前台应用再切回来时，连接可能僵住一段时间，
/// 设太短会被误判成「下载失败」（加班记踩过这个坑，这里沿用同样的取值）。
Future<HttpClientResponse> openHttpConnection(
    Uri url, Map<String, String> headers) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 30);
  try {
    final HttpClientRequest req = await client.getUrl(url);
    req.followRedirects = false; // 自己跟，保证每一跳都带 Range
    headers.forEach(req.headers.set);
    return await req.close();
  } catch (_) {
    client.close(force: true);
    rethrow;
  }
}

/// APK 下载器。
class ApkDownloader {
  ApkDownloader({
    required this.openConnection,
    required this.now,
  });

  /// 打开一个 HTTP 连接的注入点（测试替换用）。
  final Future<HttpClientResponse> Function(Uri url, Map<String, String> headers)
      openConnection;

  /// 时钟注入（退避计算用，测试可跳过真实等待）。
  final Future<void> Function(Duration) now;

  static const int _bufferSize = 64 * 1024;

  /// 进度节流：累计这么多字节才回调一次，避免高频重建界面。
  static const int _progressStep = 128 * 1024;

  /// 单个地址最多重试几次。
  static const int maxRetries = 8;

  /// 手动跟跳转的次数上限（Gitee 要经两次 302）。
  static const int _maxRedirects = 5;

  /// 下载 [url] 到 [target]。
  ///
  /// [expectedSha256] 非空时会校验；不符直接删文件并返回失败——
  /// 「下载回来的东西不是官方那一份」绝不能拿去安装。
  ///
  /// [cancel] 返回 true 时尽快退出，已下部分保留（下次可续传）。
  Future<ApkDownloadResult> download({
    required String url,
    required File target,
    String expectedSha256 = '',
    int expectedSize = 0,
    void Function(ApkProgress)? onProgress,
    bool Function()? cancel,
  }) async {
    if (url.isEmpty) {
      return const ApkDownloadResult(ok: false, error: '没有可用的下载地址');
    }
    await target.parent.create(recursive: true);

    // 已存在的文件分两种情况（0.2.70）：
    //   - 大小正好等于期望 → 可能是上次已下完：校验通过就直接用；
    //     校验不过说明是坏包，删掉重下。
    //   - 大小不等 → 这是上次中断留下的半包，**保留它用于续传**，
    //     绝不能删（删了就等于每次都从头下，断点续传形同虚设）。
    if (await target.exists() && expectedSize > 0) {
      final int len = await target.length();
      if (len == expectedSize) {
        if (await _verify(target, expectedSha256)) {
          return ApkDownloadResult(ok: true, path: target.path);
        }
        // 大小对但哈希不对：坏包，删掉重下
        await _deleteQuietly(target);
      } else if (len > expectedSize) {
        // 比目标还大：一定是坏的（比如把旧版本残留当成了半包），删掉
        await _deleteQuietly(target);
      }
      // len < expectedSize 什么都不做：留给断点续传
    }

    String lastError = '下载失败，请检查网络后重试';
    bool noResume = false;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      if (cancel?.call() ?? false) {
        return const ApkDownloadResult(ok: false, cancelled: true);
      }
      try {
        final _AttemptResult r = await _downloadOnce(
          url: url,
          target: target,
          expectedSize: expectedSize,
          noResume: noResume,
          onProgress: onProgress,
          cancel: cancel,
        );
        if (r.cancelled) {
          return const ApkDownloadResult(ok: false, cancelled: true);
        }
        if (r.noResumeDetected) {
          // 该源不支持续传：清掉半包，下一轮从 0 开始
          noResume = true;
          await _deleteQuietly(target);
        }
        if (r.complete) {
          if (!await _verify(target, expectedSha256)) {
            await _deleteQuietly(target);
            return const ApkDownloadResult(
              ok: false,
              error: '下载的安装包校验不通过，已删除。请到发布页手动下载',
            );
          }
          return ApkDownloadResult(ok: true, path: target.path);
        }
        lastError = r.error.isEmpty ? lastError : r.error;
      } catch (e) {
        lastError = '下载中断：$e';
      }
      if (attempt < maxRetries - 1) {
        // 退避：1s、2s、3s…（切后台时这段等待会被系统挂起，回来继续）
        await now(Duration(seconds: attempt + 1));
      }
    }
    return ApkDownloadResult(ok: false, error: lastError);
  }

  /// 校验文件：大小对（调用方已查）+ 哈希对（清单给了才算）。
  Future<bool> _verify(File f, String expectedSha256) async {
    final String want = expectedSha256.trim().toLowerCase();
    if (want.isEmpty) return true; // 清单没给哈希，跳过
    try {
      final Uint8List bytes = await f.readAsBytes();
      return sha256Hex(bytes) == want;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉不影响下次覆盖写
    }
  }

  /// 单个地址的一次尝试。
  Future<_AttemptResult> _downloadOnce({
    required String url,
    required File target,
    required int expectedSize,
    required bool noResume,
    void Function(ApkProgress)? onProgress,
    bool Function()? cancel,
  }) async {
    final bool exists = await target.exists();
    int existing = (!noResume && exists) ? await target.length() : 0;
    // 重置进度基准：不支持续传时必须从 0 开始显示，否则进度条会往回跳
    if (noResume) existing = 0;

    final Map<String, String> headers = <String, String>{
      'User-Agent': 'MusicOrganizer-Update',
      'Accept': 'application/octet-stream',
      if (existing > 0) 'Range': 'bytes=$existing-',
    };

    final Uri uri = Uri.parse(url);
    HttpClientResponse resp = await openConnection(uri, headers);

    // 手动跟 302/301/303/307/308，每一跳都重新带上 Range
    int redirects = 0;
    while (resp.isRedirect) {
      final String? loc = resp.headers.value(HttpHeaders.locationHeader);
      if (loc == null || loc.isEmpty) {
        return const _AttemptResult(complete: false, error: '跳转地址缺失');
      }
      redirects++;
      if (redirects > _maxRedirects) {
        return const _AttemptResult(complete: false, error: '跳转次数过多');
      }
      final Uri next = uri.resolve(loc);
      resp = await openConnection(next, headers);
    }

    bool noResumeDetected = false;
    int startOffset;
    int total;
    if (resp.statusCode == HttpStatus.partialContent) {
      // 206：服务器接受续传
      startOffset = existing;
      total = existing + (resp.contentLength > 0 ? resp.contentLength : 0);
    } else if (resp.statusCode == HttpStatus.ok) {
      // 200：整包返回。若我们发过 Range，说明这个源不支持续传。
      // **必须立刻中止本轮**：半包还在文件里，若继续往尾部追加整包内容，
      // 得到的是「半包 + 完整包」的垃圾，大小对不上、哈希更对不上。
      // 交给外层清空文件后重来（进度也从 0 重新显示，不会往回跳）。
      if (existing > 0) {
        return const _AttemptResult(
          complete: false,
          noResumeDetected: true,
          error: '该下载源不支持断点续传，正在重新下载',
        );
      }
      startOffset = 0;
      total = resp.contentLength > 0 ? resp.contentLength : expectedSize;
    } else {
      return _AttemptResult(
        complete: false,
        error: '服务器返回 ${resp.statusCode}',
        noResumeDetected: noResumeDetected,
      );
    }

    int lastReported = -1;
    void report(int got) {
      if (onProgress == null) return;
      if (lastReported >= 0 && (got - lastReported).abs() < _progressStep) {
        // 字节增量不够时，只在百分比跨档才刷新
        final int a = total > 0 ? lastReported * 100 ~/ total : -1;
        final int b = total > 0 ? got * 100 ~/ total : -1;
        if (a == b) return;
      }
      lastReported = got;
      onProgress(ApkProgress(got, total));
    }

    report(startOffset);

    RandomAccessFile? raf;
    int received = startOffset;
    try {
      // 续传时用 append（位置已在末尾）；从头下载时先截断，避免残留尾部字节
      if (startOffset > 0 && exists) {
        raf = await target.open(mode: FileMode.append);
      } else {
        raf = await target.open(mode: FileMode.write);
      }

      await for (final List<int> chunk in resp) {
        if (cancel?.call() ?? false) {
          await raf.close();
          return const _AttemptResult(complete: false, cancelled: true);
        }
        // 按 _bufferSize 分片写：HttpClientResponse 的 chunk 大小不保证，
        // 一次 writeFrom 大段会把内存峰值推高
        for (int i = 0; i < chunk.length; i += _bufferSize) {
          final int end =
              i + _bufferSize < chunk.length ? i + _bufferSize : chunk.length;
          await raf.writeFrom(chunk.sublist(i, end));
        }
        received += chunk.length;
        report(received);
      }
      await raf.flush();
      await raf.close();
      raf = null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }

    final int size = await target.length();
    final int wantSize = expectedSize > 0 ? expectedSize : total;
    final bool complete = wantSize > 0 && size == wantSize && size > 0;
    return _AttemptResult(
      complete: complete,
      error: complete ? '' : '下载不完整（$size / $wantSize 字节）',
      noResumeDetected: noResumeDetected,
    );
  }
}

class _AttemptResult {
  const _AttemptResult({
    required this.complete,
    this.error = '',
    this.cancelled = false,
    this.noResumeDetected = false,
  });

  final bool complete;
  final String error;
  final bool cancelled;
  final bool noResumeDetected;
}
