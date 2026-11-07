import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/theme/palette.dart';

/// WCAG 2.x 对比度：(亮+0.05)/(暗+0.05)。用 Flutter 自带的
/// [Color.computeLuminance]（就是 sRGB 线性化后的相对亮度），生产代码不加依赖。
double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = math.max(la, lb);
  final double lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('色板对比度（WCAG 2.x，正文阈值 4.5）', () {
    for (final (String name, MoPalette p) in <(String, MoPalette)>[
      ('浅色', MoPalette.light),
      ('深色', MoPalette.dark),
    ]) {
      test('$name：所有文字角色对底色 ≥ 4.5', () {
        expect(_contrast(p.text, p.bg), greaterThanOrEqualTo(4.5),
            reason: '$name text/bg');
        expect(_contrast(p.body, p.bg), greaterThanOrEqualTo(4.5),
            reason: '$name body/bg');
        expect(_contrast(p.sub, p.bg), greaterThanOrEqualTo(4.5),
            reason: '$name sub/bg');
        expect(_contrast(p.sub, p.card), greaterThanOrEqualTo(4.5),
            reason: '$name sub/card');
        expect(_contrast(p.onSurfacePrimary, p.bg), greaterThanOrEqualTo(4.5),
            reason: '$name onSurfacePrimary/bg');
        expect(_contrast(p.onPrimary, p.primary), greaterThanOrEqualTo(4.5),
            reason: '$name onPrimary/primary');
      });

      test('$name：语义色在底色上 ≥ 4.5（旧版 warn 只有 2.6）', () {
        expect(_contrast(p.ok, p.bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(p.warn, p.bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(p.err, p.bg), greaterThanOrEqualTo(4.5));
      });

      test('$name：三级弱化 faint 对底色 ≥ 3.0（装饰级）', () {
        expect(_contrast(p.faint, p.bg), greaterThanOrEqualTo(3.0));
      });
    }
  });

  test('主色不再是绿色：accent 与 primary 同色系', () {
    // 旧版 minimal 的 accent 是 #10B981（绿），用户反馈「一屏绿紫」。
    expect(MoPalette.light.accent, isNot(const Color(0xFF10B981)));
    expect(MoPalette.light.accent, MoPalette.light.primary);
    expect(MoPalette.dark.accent, MoPalette.dark.primary);
  });

  group('MoPalette.fromSystem（Android 12+ 动态色）', () {
    test('缺键回退到同明暗的固定色板', () {
      final MoPalette p = MoPalette.fromSystem(<String, int>{}, dark: false);
      expect(p.bg, MoPalette.light.bg);
      expect(p.card, MoPalette.light.card);
      expect(p.text, MoPalette.light.text);
      expect(p.primary, MoPalette.light.primary);
      expect(p.line, MoPalette.light.line);
    });

    test('给了系统色就采用（RGB 值补不透明）', () {
      final MoPalette p = MoPalette.fromSystem(<String, int>{
        'n1_50': 0x102030,
        'n1_10': 0xFFFFFF,
        'a1_600': 0x204060,
        'n1_900': 0x0A0B0C,
      }, dark: false);
      expect(p.bg, const Color(0xFF102030));
      expect(p.card, const Color(0xFFFFFFFF));
      expect(p.primary, const Color(0xFF204060));
      expect(p.text, const Color(0xFF0A0B0C));
    });

    test('语义色不跟壁纸变：ok / warn / err 始终取固定色板', () {
      final MoPalette p = MoPalette.fromSystem(<String, int>{
        'a1_600': 0xFF00FF,
        'n1_50': 0x123456,
      }, dark: false);
      expect(p.ok, MoPalette.light.ok);
      expect(p.warn, MoPalette.light.warn);
      expect(p.err, MoPalette.light.err);
    });

    test('深色取 accent1_200 / neutral1_900 那一档', () {
      final MoPalette p = MoPalette.fromSystem(<String, int>{
        'a1_200': 0x99AAFF,
        'n1_900': 0x101218,
      }, dark: true);
      expect(p.primary, const Color(0xFF99AAFF));
      expect(p.bg, const Color(0xFF101218));
      // 没给的字段回退深色色板，不会串成浅色
      expect(p.card, MoPalette.dark.card);
    });
  });
}
