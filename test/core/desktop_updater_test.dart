import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/update/desktop_updater.dart';
import 'package:musicorganizer/core/update/sha256.dart';

void main() {
  final Uint8List pkg = Uint8List.fromList(utf8.encode('MusicOrganizer zip 内容'));
  final String goodSha = sha256Hex(pkg);

  test('大小与 SHA256 都对 → 通过', () {
    expect(
      DesktopUpdater.verifyZip(pkg,
          expectedSize: pkg.length, expectedSha256: goodSha),
      '',
    );
  });

  test('改一个字节（SHA256 对不上）→ 拒绝', () {
    final Uint8List tampered = Uint8List.fromList(pkg);
    tampered[0] ^= 0xFF;
    final String err = DesktopUpdater.verifyZip(tampered,
        expectedSize: pkg.length, expectedSha256: goodSha);
    expect(err, isNotEmpty);
    expect(err, contains('校验'));
  });

  test('清单里的大小写错一个数字 → 拒绝', () {
    final String err = DesktopUpdater.verifyZip(pkg,
        expectedSize: pkg.length + 1, expectedSha256: goodSha);
    expect(err, isNotEmpty);
    expect(err, contains('大小'));
  });

  test('清单没给大小与哈希（老版本）→ 放行但标记未校验', () {
    expect(DesktopUpdater.verifyZip(pkg), '');
    expect(DesktopUpdater.hasVerification(0, ''), isFalse);
    expect(DesktopUpdater.hasVerification(pkg.length, goodSha), isTrue);
  });

  test('校验提示按清单完整度分三种（都要先问用户）', () {
    // 大小 + 哈希都有：完整校验，不用问
    expect(DesktopUpdater.confirmTextFor(100, 'abc'), isNull);
    // 只有大小
    final String? onlySize = DesktopUpdater.confirmTextFor(100, '');
    // 只有哈希
    final String? onlySha = DesktopUpdater.confirmTextFor(0, 'abc');
    // 都没有
    final String? none = DesktopUpdater.confirmTextFor(0, '');

    expect(onlySize, isNotNull);
    expect(onlySize, contains('只校验了大小'));
    expect(onlySha, isNotNull);
    expect(onlySha, contains('SHA-256'));
    expect(none, isNotNull);
    expect(none, contains('未校验安装包'));
    // 三种提示各不相同
    expect(<String?>{onlySize, onlySha, none}.length, 3);
  });

  test('更新脚本复制失败时不重启不删自己（J）', () {
    final String bat = DesktopUpdater.windowsApplyScript('/from', '/to');
    expect(bat, contains('xcopy'));
    expect(bat, contains('errorlevel'));
    expect(bat, contains('exit /b 1'));
    expect(bat, contains('mo-update-failed'));

    final String sh = DesktopUpdater.posixApplyScript('/from', '/to');
    expect(sh, contains('if ! cp'));
    expect(sh, contains('exit 1'));
    expect(sh, contains('mo-update-failed'));
  });
}
