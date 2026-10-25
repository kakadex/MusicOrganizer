import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/net/proxy_settings.dart';
import 'package:musicorganizer/core/settings/settings_backup.dart';

void main() {
  setUp(NetworkProxy.reset);
  tearDown(NetworkProxy.reset);

  group('地址解析', () {
    test('host:port', () {
      final ProxyEndpoint? ep = NetworkProxy.parseSpec('127.0.0.1:7890');
      expect(ep, isNotNull);
      expect(ep!.host, '127.0.0.1');
      expect(ep.port, 7890);
      expect(ep.spec, 'PROXY 127.0.0.1:7890');
    });

    test('http:// 前缀与结尾斜杠都能吃掉', () {
      final ProxyEndpoint? ep = NetworkProxy.parseSpec('http://127.0.0.1:8080/');
      expect(ep!.port, 8080);
    });

    test('带账号密码时只取主机端口（dart:io 不支持认证代理）', () {
      final ProxyEndpoint? ep = NetworkProxy.parseSpec('u:p@10.0.0.2:3128');
      expect(ep!.host, '10.0.0.2');
      expect(ep.port, 3128);
    });

    test('SOCKS 明确拒绝并给出原因', () {
      expect(NetworkProxy.parseSpec('socks5://127.0.0.1:1080'), isNull);
      expect(NetworkProxy.lastError, contains('SOCKS'));
    });

    test('缺端口 / 端口越界 / 空串 → null', () {
      expect(NetworkProxy.parseSpec('127.0.0.1'), isNull);
      expect(NetworkProxy.parseSpec('127.0.0.1:0'), isNull);
      expect(NetworkProxy.parseSpec('127.0.0.1:70000'), isNull);
      expect(NetworkProxy.parseSpec(''), isNull);
      expect(NetworkProxy.parseSpec(null), isNull);
    });
  });

  group('环境变量', () {
    test('HTTPS_PROXY 优先，其次 HTTP_PROXY，再 ALL_PROXY', () {
      expect(
        NetworkProxy.parseEnv(<String, String>{
          'HTTPS_PROXY': 'http://1.1.1.1:1111',
          'HTTP_PROXY': 'http://2.2.2.2:2222',
        })!.port,
        1111,
      );
      expect(
        NetworkProxy.parseEnv(<String, String>{'HTTP_PROXY': 'http://2.2.2.2:2222'})!.port,
        2222,
      );
      expect(
        NetworkProxy.parseEnv(<String, String>{'all_proxy': 'http://3.3.3.3:3333'})!.port,
        3333,
      );
    });

    test('空值跳过，全空返回 null', () {
      expect(NetworkProxy.parseEnv(<String, String>{'HTTPS_PROXY': '  '}), isNull);
      expect(NetworkProxy.parseEnv(<String, String>{}), isNull);
    });
  });

  group('模式与生效值', () {
    test('默认直连', () {
      expect(NetworkProxy.mode, ProxyMode.direct);
      expect(NetworkProxy.effective, isNull);
      expect(NetworkProxy.findProxy(Uri.parse('https://x')), 'DIRECT');
      expect(NetworkProxy.describe(), '直连');
    });

    test('手动模式生效，findProxy 给出 PROXY', () {
      NetworkProxy.configure(ProxyMode.manual, host: '127.0.0.1', port: '56056');
      expect(NetworkProxy.effective!.port, 56056);
      expect(NetworkProxy.findProxy(Uri.parse('https://music.163.com')),
          'PROXY 127.0.0.1:56056');
      expect(NetworkProxy.describe(), contains('手动'));
    });

    test('手动填错 → 退回直连并留错误原因（不静默）', () {
      NetworkProxy.configure(ProxyMode.manual, host: '', port: '');
      expect(NetworkProxy.mode, ProxyMode.direct);
      expect(NetworkProxy.effective, isNull);
      expect(NetworkProxy.lastError, isNotEmpty);
    });

    test('自动模式读注入的环境变量', () {
      NetworkProxy.configure(ProxyMode.auto,
          env: <String, String>{'HTTPS_PROXY': 'http://9.9.9.9:9999'});
      expect(NetworkProxy.mode, ProxyMode.auto);
      expect(NetworkProxy.effective!.port, 9999);
    });

    test('自动模式但没有环境变量 → 按直连处理，描述里说明', () {
      NetworkProxy.configure(ProxyMode.auto, env: <String, String>{});
      expect(NetworkProxy.effective, isNull);
      expect(NetworkProxy.describe(), contains('直连'));
    });
  });

  group('设置备份认得代理键', () {
    test('键位分类正确', () {
      expect(SettingsBackup.kindOf('proxy_mode'), SettingsKind.intKey);
      expect(SettingsBackup.kindOf('proxy_port'), SettingsKind.intKey);
      expect(SettingsBackup.kindOf('proxy_host'), SettingsKind.stringKey);
    });

    test('导入时端口越界会被夹回合法区间', () {
      final List<String> warnings = <String>[];
      final Object? fixed = SettingsBackup.sanitize('proxy_port', 70000, warnings);
      expect(fixed, 65535);
      expect(warnings, isNotEmpty);
    });

    test('导入时模式越界会被夹回 0~2', () {
      final List<String> warnings = <String>[];
      expect(SettingsBackup.sanitize('proxy_mode', 9, warnings), 2);
    });

    test('主机名过长会丢弃', () {
      final List<String> warnings = <String>[];
      expect(SettingsBackup.sanitize('proxy_host', 'x' * 200, warnings), isNull);
    });
  });
}
