import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/version.dart';

void main() {
  test('version.dart 常量格式符合 X.Y.Z-abc123 约定', () {
    expect(
      RegExp(r'^\d+\.\d+\.\d+-[0-9a-z]{6}$').hasMatch(kAppVersionFull),
      isTrue,
      reason: kAppVersionFull,
    );
    expect(kAppVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(kAppBuild, greaterThan(0));
    expect(kAppVersionFull.startsWith('$kAppVersion-'), isTrue);
  });
}
