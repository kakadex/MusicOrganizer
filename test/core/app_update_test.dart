import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/update/app_update.dart';

const String _manifestUrl =
    'https://gitee.com/kakadex/MusicOrganizer/raw/main/dist/latest.txt';

void main() {
  group('版本比较', () {
    test('按数字段逐段比较，缺段补 0', () {
      expect(AppUpdate.compare('0.1.10', '0.1.9'), greaterThan(0));
      expect(AppUpdate.compare('0.1.9', '0.1.10'), lessThan(0));
      expect(AppUpdate.compare('1.0', '1.0.0'), 0);
      expect(AppUpdate.compare('v0.2.0', '0.2.0'), 0);
      expect(AppUpdate.compare('  V1.2.3 ', '1.2.3'), 0);
    });

    test('预发布版本比同号正式版旧', () {
      expect(AppUpdate.compare('0.2.0-beta', '0.2.0'), lessThan(0));
      expect(AppUpdate.compare('0.2.0-rc1', '0.2.0'), lessThan(0));
      expect(AppUpdate.compare('0.2.0', '0.2.0-alpha'), greaterThan(0));
      expect(AppUpdate.compare('0.2.0', '0.2.0'), 0);
    });

    test('异常输入不抛异常', () {
      expect(AppUpdate.compare('', ''), 0);
      expect(AppUpdate.compare(null, null), 0);
      expect(AppUpdate.compare('abc', '0.0.0'), 0);
      expect(AppUpdate.compare('0.2.0', null), greaterThan(0));
    });

    test('isNewer 判定与空值处理', () {
      expect(AppUpdate.isNewer('0.2.0', '0.2.1'), isTrue);
      expect(AppUpdate.isNewer('0.2.0', 'v0.2.0'), isFalse);
      expect(AppUpdate.isNewer('0.2.0', '0.2.0-beta'), isFalse);
      expect(AppUpdate.isNewer('0.2.0', ''), isFalse);
      expect(AppUpdate.isNewer('0.2.0', null), isFalse);
    });

    test('normalize / stripPrefix / display', () {
      expect(AppUpdate.normalize('v0.1.11 '), '0.1.11');
      expect(AppUpdate.normalize('0.2.0-rc1'), '0.2.0');
      expect(AppUpdate.normalize(''), '');
      expect(AppUpdate.stripPrefix(' v0.2.0-Beta '), '0.2.0-Beta');
      expect(AppUpdate.display('0.2.0'), 'v0.2.0');
      expect(AppUpdate.display('beta'), 'beta');
      expect(AppUpdate.display(''), '');
    });
  });

  group('体积格式化', () {
    test('按 1024 进制，未知或负数返回空串', () {
      expect(AppUpdate.humanSize(0), '');
      expect(AppUpdate.humanSize(-1), '');
      expect(AppUpdate.humanSize(512), '512 B');
      expect(AppUpdate.humanSize(1024), '1 KB');
      expect(AppUpdate.humanSize(402895), '393 KB');
      expect(AppUpdate.humanSize(3 * 1024 * 1024), '3.0 MB');
    });
  });

  group('版本清单', () {
    test('解析标准清单并拼出绝对下载地址', () {
      const String text = '''
# 版本清单
version=0.1.100-84f89b
code=111
tag=v0.1.100-84f89b
apk=dist/musicorganizer-latest.apk
size=402895
sha256=3937c9cab0268cf3997739788ec662da329a55ea9f96eab2ed66c2c0611bfd4a
summary=音乐文件整理工具 v0.1.100
page=https://gitee.com/kakadex/MusicOrganizer/releases
''';
      final Release? r = AppUpdate.parseManifest(text, _manifestUrl);
      expect(r, isNotNull);
      expect(r!.tag, 'v0.1.100-84f89b');
      expect(r.version, '0.1.100-84f89b');
      expect(r.apkName, 'musicorganizer-latest.apk');
      expect(r.apkUrl,
          'https://gitee.com/kakadex/MusicOrganizer/raw/main/dist/musicorganizer-latest.apk');
      expect(r.apkSize, 402895);
      expect(r.sha256, startsWith('3937c9'));
      expect(r.notes, '音乐文件整理工具 v0.1.100');
      expect(r.pageUrl, endsWith('/releases'));
      expect(r.prerelease, isFalse);
      expect(r.hasApk, isTrue);
    });

    test('兼容 key: value，并识别预发布', () {
      const String text = '''
version: 1.2.3
tag: v1.2.3-beta
apk: https://example.com/a.apk
size: 2048
''';
      final Release? r = AppUpdate.parseManifest(text, _manifestUrl);
      expect(r, isNotNull);
      expect(r!.version, '1.2.3');
      expect(r.apkUrl, 'https://example.com/a.apk');
      expect(r.prerelease, isTrue);
    });

    test('缺 tag 时用 version 补；缺版本信息返回 null', () {
      final Release? r =
          AppUpdate.parseManifest('version=0.4.0\ndate=2026-10-25', _manifestUrl);
      expect(r, isNotNull);
      expect(r!.tag, 'v0.4.0');
      expect(r.apkUrl, '');
      expect(r.hasApk, isFalse);

      expect(AppUpdate.parseManifest('summary=只有说明', _manifestUrl), isNull);
      expect(AppUpdate.parseManifest('', _manifestUrl), isNull);
      expect(AppUpdate.parseManifest(null, _manifestUrl), isNull);
      expect(AppUpdate.parseManifest('https://example.com/latest.txt', ''), isNull);
    });

    test('体积写错按未知处理', () {
      final Release? r =
          AppUpdate.parseManifest('version=1.0.0\nsize=很大', _manifestUrl);
      expect(r, isNotNull);
      expect(r!.apkSize, 0);
    });
  });

  group('GitHub Release', () {
    test('取第一个 apk 资产与 sha256', () {
      final Map<String, Object?> json = <String, Object?>{
        'tag_name': 'v0.3.0',
        'body': '### 新增\n- 修复',
        'html_url': 'https://github.com/kakadex/MusicOrganizer/releases/tag/v0.3.0',
        'prerelease': false,
        'assets': <Object?>[
          <String, Object?>{
            'name': '说明.txt',
            'browser_download_url': 'https://example.com/readme.txt',
          },
          <String, Object?>{
            'name': 'app-release.apk',
            'browser_download_url': 'https://example.com/app-release.apk',
            'size': 123456,
            'digest': 'sha256:abcdef',
          },
        ],
      };
      final Release? r = AppUpdate.parseRelease(json);
      expect(r, isNotNull);
      expect(r!.tag, 'v0.3.0');
      expect(r.version, '0.3.0');
      expect(r.apkName, 'app-release.apk');
      expect(r.apkUrl, 'https://example.com/app-release.apk');
      expect(r.apkSize, 123456);
      expect(r.sha256, 'abcdef');
      expect(r.pageUrl, contains('/releases/tag/'));
    });

    test('接受 JSON 文本；缺 tag_name 或非对象返回 null', () {
      const String text = '{"tag_name":"v1.0.0","name":"正式版"}';
      expect(AppUpdate.parseRelease(text)?.version, '1.0.0');
      expect(AppUpdate.parseRelease('{"name":"没有 tag"}'), isNull);
      expect(AppUpdate.parseRelease('不是 JSON'), isNull);
      expect(AppUpdate.parseRelease(<Object?>[]), isNull);
    });

    test('draft 也算预发布；没有资产时 apk 为空', () {
      final Release? r = AppUpdate.parseRelease(<String, Object?>{
        'tag_name': 'v2.0.0',
        'draft': true,
        'assets': <Object?>[],
      });
      expect(r, isNotNull);
      expect(r!.prerelease, isTrue);
      expect(r.hasApk, isFalse);
    });
  });

  group('更新说明整理', () {
    test('标题转方括号，去掉链接与粗体', () {
      const String body = '''
### 新增
- 修复 **标签** 写入
[主页](https://example.com) 有说明

#### 其它''';
      expect(
        AppUpdate.shortNotes(body, 10),
        '【新增】\n- 修复 标签 写入\n主页 有说明\n\n【其它】',
      );
    });

    test('超过行数截断并补省略号', () {
      expect(AppUpdate.shortNotes('a\nb\nc', 2), 'a\nb\n…');
      expect(AppUpdate.shortNotes('', 5), '');
      expect(AppUpdate.shortNotes(null, 5), '');
    });

    test('单行过长时截断并提示去发布页', () {
      final String long = 'x' * 950;
      final String out = AppUpdate.shortNotes(long, 10);
      expect(out, contains('…（完整说明见发布页）'));
      expect(out.length, lessThan(120));
    });
  });
}
