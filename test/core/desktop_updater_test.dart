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
}
