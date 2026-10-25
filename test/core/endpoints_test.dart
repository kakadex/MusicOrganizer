import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/source/endpoints.dart';

/// 内存版配置，模拟 SharedPreferences。
class FakeConfig implements EndpointsConfig {
  final Map<String, String> urls = <String, String>{};
  final Map<String, bool> on = <String, bool>{};

  @override
  String? overrideUrl(String endpointKey) => urls[endpointKey];

  @override
  bool enabled(String sourceKey) => on[sourceKey] ?? true;

  @override
  void setOverride(String endpointKey, String? url) {
    if (url == null || url.trim().isEmpty) {
      urls.remove(endpointKey);
    } else {
      urls[endpointKey] = url.trim();
    }
  }

  @override
  void setEnabled(String sourceKey, bool enabled) => on[sourceKey] = enabled;
}

void main() {
  test('默认地址（未注入配置）', () {
    Endpoints.uninstall();
    expect(Endpoints.urlOf('netease', 0), 'https://music.163.com/api/search/get');
    expect(Endpoints.urlOf('kuwo', 0), 'https://search.kuwo.cn/r.s');
    expect(Endpoints.urlOf('lyric_qq', 1),
        'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg');
    expect(Endpoints.urlOf('nope', 0), '');
    expect(Endpoints.enabled('netease'), isTrue);
    expect(Endpoints.sources.length, 15);
    expect(Endpoints.customized('netease.0'), isFalse);
    expect(Endpoints.urlOf('update', 0),
        'https://api.github.com/repos/kakadex/MusicOrganizer/releases/latest');
    expect(Endpoints.urlOf('update', 1),
        'https://github.com/kakadex/MusicOrganizer/releases/latest');
    expect(Endpoints.urlOf('update', 2),
        'https://github.com/kakadex/MusicOrganizer');
    expect(Endpoints.isEndpointKey('update.0'), isTrue);
  });

  test('用户覆盖地址', () {
    final FakeConfig cfg = FakeConfig();
    Endpoints.install(cfg);
    expect(Endpoints.urlOf('kuwo', 0), 'https://search.kuwo.cn/r.s');
    cfg.setOverride('kuwo.0', 'https://mirror.example.com/kw');
    expect(Endpoints.urlOf('kuwo', 0), 'https://mirror.example.com/kw');
    expect(Endpoints.customized('kuwo.0'), isTrue);
    expect(Endpoints.urlOf('netease', 0), 'https://music.163.com/api/search/get');

    cfg.setOverride('kuwo.0', '   ');
    expect(Endpoints.urlOf('kuwo', 0), 'https://search.kuwo.cn/r.s');
    expect(Endpoints.customized('kuwo.0'), isFalse);

    cfg.setOverride('kuwo.0', '  https://x.example.com/a  ');
    expect(Endpoints.urlOf('kuwo', 0), 'https://x.example.com/a');
  });

  test('启用开关', () {
    final FakeConfig cfg = FakeConfig();
    Endpoints.install(cfg);
    expect(Endpoints.enabled('migu'), isTrue);
    cfg.setEnabled('migu', false);
    expect(Endpoints.enabled('migu'), isFalse);
    expect(Endpoints.enabled('kuwo'), isTrue);
    cfg.setEnabled('migu', true);
    expect(Endpoints.enabled('migu'), isTrue);
  });

  test('恢复默认', () {
    final FakeConfig cfg = FakeConfig();
    Endpoints.install(cfg);
    cfg.setOverride('netease.0', 'https://a.example.com/x');
    cfg.setOverride('lrclib.1', 'https://b.example.com/y');
    cfg.setEnabled('kugou', false);
    Endpoints.resetAll();
    expect(Endpoints.urlOf('netease', 0), 'https://music.163.com/api/search/get');
    expect(Endpoints.urlOf('lrclib', 1), 'https://lrclib.net/api/search');
    expect(Endpoints.enabled('kugou'), isFalse);
  });

  test('地址校验', () {
    expect(Endpoints.isValidUrl('https://a.example.com/x'), isTrue);
    expect(Endpoints.isValidUrl('http://a.example.com'), isTrue);
    expect(Endpoints.isValidUrl('  https://a.example.com/x '), isTrue);
    expect(Endpoints.isValidUrl('ftp://a.example.com'), isFalse);
    expect(Endpoints.isValidUrl('a.example.com/x'), isFalse);
    expect(Endpoints.isValidUrl('https://a example.com'), isFalse);
    expect(Endpoints.isValidUrl(''), isFalse);
    expect(Endpoints.isValidUrl(null), isFalse);
    expect(Endpoints.isValidUrl('https://'), isFalse);
    expect(Endpoints.isValidUrl('https:///path'), isFalse);
  });
}
