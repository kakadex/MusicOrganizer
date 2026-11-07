import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/theme/font_scale.dart';

/// 字体缩放（0.4.x）的纯逻辑回归。
///
/// 2026-11-07 真机 bug：设置 150% 后重启又回到 100%——根因是
/// `Repo._loadSettings` 的持久化白名单漏了 `font_scale` 键。
/// 这里锁两件事：
///   1. 缩放值只能在合法区间内、且档位必须是整数倍（非整数倍会让
///      Windows 上文字笔画粗细不匀）；
///   2. 档位常量的具体取值（防止有人又加回 1.15 / 1.3）。
void main() {
  group('FontScale', () {
    setUp(() => FontScale.instance.set(FontScale.defaultScale));
    tearDown(() => FontScale.instance.set(FontScale.defaultScale));

    test('设置后能读回（内存态）', () {
      FontScale.instance.set(1.5);
      expect(FontScale.instance.scale, 1.5);
    });

    test('越界自动夹到合法区间', () {
      FontScale.instance.set(99);
      expect(FontScale.instance.scale, FontScale.maxScale);
      FontScale.instance.set(0.01);
      expect(FontScale.instance.scale, FontScale.minScale);
    });

    test('档位只能是整数倍（非整数倍会让 Windows 字形发毛）', () {
      // 1.15 / 1.3 这类在 Windows 上会算错笔画宽度 → 粗细不匀
      for (final double v in FontScale.steps) {
        expect(v * 100 % 25, 0,
            reason: '档位 ${FontScale.label(v)} 不是 25% 的整数倍，'
                'Windows 上文字会发毛');
        expect(v, greaterThanOrEqualTo(FontScale.minScale));
        expect(v, lessThanOrEqualTo(FontScale.maxScale));
      }
    });

    test('档位包含 100% 且桌面默认就是 100%', () {
      expect(FontScale.steps, contains(1.0));
      expect(FontScale.desktopDefaultScale, 1.0,
          reason: '桌面默认必须是整数倍，否则默认观感就发毛');
    });

    test('百分比文案', () {
      expect(FontScale.label(1.0), '100%');
      expect(FontScale.label(1.25), '125%');
      expect(FontScale.label(1.5), '150%');
    });

    test('重复设同一个值不触发通知', () {
      int calls = 0;
      void listener() => calls++;
      FontScale.instance.addListener(listener);
      FontScale.instance.set(1.0);
      expect(calls, 0, reason: '值没变不应该通知重建');
      FontScale.instance.set(1.25);
      expect(calls, 1);
      FontScale.instance.removeListener(listener);
    });
  });
}
