// ignore_for_file: file_names, avoid_print

/// 联网自检（手工运行，不进单元测试）：走的是 App 里同一套 HTTP 代码与代理配置。
///
/// 用途：换网络 / 配了代理之后，先确认「出口通不通」，再排查数据源本身。
///
/// 用法：
/// ```bash
/// dart run tools/net_smoke.dart                  # 直连
/// dart run tools/net_smoke.dart --auto           # 读环境变量里的代理
/// dart run tools/net_smoke.dart --manual 127.0.0.1:7890
/// ```
library;

import 'dart:io';

import 'package:musicorganizer/core/net/http_client.dart';
import 'package:musicorganizer/core/net/proxy_settings.dart';
import 'package:musicorganizer/core/source/endpoints.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--manual')) {
    final int at = args.indexOf('--manual');
    final String spec = at + 1 < args.length ? args[at + 1] : '';
    NetworkProxy.configure(
      ProxyMode.manual,
      host: spec.contains(':') ? spec.substring(0, spec.lastIndexOf(':')) : spec,
      port: spec.contains(':') ? spec.substring(spec.lastIndexOf(':') + 1) : '',
    );
  } else if (args.contains('--auto')) {
    NetworkProxy.configure(ProxyMode.auto);
  } else {
    NetworkProxy.configure(ProxyMode.direct);
  }
  Http.reset();
  print('代理：${NetworkProxy.describe()}'
      '${NetworkProxy.lastError.isEmpty ? '' : '（${NetworkProxy.lastError}）'}');
  print('');

  // 四项代表：国内站 / 海外站 / 歌词站 / 版本清单
  final List<List<String>> checks = <List<String>>[
    <String>['网易云搜索', Endpoints.urlOf('netease', 0), 's=test&type=1&limit=1'],
    <String>['Deezer 搜索', Endpoints.urlOf('deezer', 0), 'q=test&limit=1'],
    <String>['LRCLIB 模糊搜索', Endpoints.urlOf('lrclib', 1), 'q=test'],
    <String>['Gitee 版本清单', Endpoints.urlOf('gitee', 0), ''],
  ];

  int ok = 0;
  for (final List<String> c in checks) {
    final String label = c[0];
    final Map<String, String>? params = c[2].isEmpty
        ? null
        : <String, String>{
            for (final String kv in c[2].split('&'))
              kv.split('=')[0]: kv.split('=')[1],
          };
    final Stopwatch sw = Stopwatch()..start();
    final String? text =
        await Http.getText(c[1], params, null, Http.readTimeoutOverseasMs);
    sw.stop();
    if (text != null) {
      ok++;
      final String head = text.length > 60 ? text.substring(0, 60) : text;
      print('✓ $label  ${sw.elapsedMilliseconds}ms  ${head.replaceAll('\n', ' ')}');
    } else {
      print('✗ $label  ${sw.elapsedMilliseconds}ms  ${Http.lastError}');
    }
  }
  print('');
  print('结果：$ok/${checks.length} 通');
  exitCode = ok == checks.length ? 0 : 1;
}
