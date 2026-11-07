import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/app/theme/mo_colors.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/app/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

SystemPaletteSet _system() => SystemPaletteSet(
      light: MoPalette.fromSystem(<String, int>{'n1_50': 0x112233}, dark: false),
      dark: MoPalette.fromSystem(<String, int>{'n1_900': 0x445566}, dark: true),
    );

MoPalette _themePalette(ThemeData t) =>
    t.extension<MoColors>()!.palette;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemeController 三态', () {
    test('默认跟随系统：交给 Flutter 决定明暗', () {
      final ThemeController c = ThemeController();
      expect(c.mode, ThemeMode.system);
      expect(c.effectiveMode, ThemeMode.system);
      expect(c.effectiveDark, isNull);
    });

    test('显式浅色 / 深色不被系统影响', () {
      final ThemeController c = ThemeController(mode: ThemeMode.dark, systemDark: false);
      expect(c.effectiveMode, ThemeMode.dark);
      expect(c.effectiveDark, isTrue);
      c.setMode(ThemeMode.light);
      expect(c.effectiveMode, ThemeMode.light);
      expect(c.effectiveDark, isFalse);
    });

    test('跟随系统 + 已知系统明暗 → 解算成明确 light/dark', () {
      final ThemeController c = ThemeController(systemDark: true);
      expect(c.effectiveMode, ThemeMode.dark);
      c.setSystemDark(false);
      expect(c.effectiveMode, ThemeMode.light);
      c.setSystemDark(null);
      expect(c.effectiveMode, ThemeMode.system);
    });

    test('通知监听：切模式与系统明暗都会触发一次', () {
      final ThemeController c = ThemeController();
      int n = 0;
      c.addListener(() => n++);
      c.setMode(ThemeMode.light);
      c.setMode(ThemeMode.light); // 同值不重复通知
      c.setSystemDark(true);
      c.setSystemDark(true);
      expect(n, 2);
    });
  });

  group('色板选择', () {
    test('跟随系统且有动态色 → 用系统色板', () {
      final ThemeController c = ThemeController(systemPalette: _system());
      expect(_themePalette(c.lightTheme).bg, const Color(0xFF112233));
      expect(_themePalette(c.darkTheme).bg, const Color(0xFF445566));
    });

    test('显式浅色 / 深色 → 一律固定色板（不显示壁纸色）', () {
      final ThemeController c =
          ThemeController(mode: ThemeMode.light, systemPalette: _system());
      expect(_themePalette(c.lightTheme).bg, MoPalette.light.bg);
      c.setMode(ThemeMode.dark);
      expect(_themePalette(c.darkTheme).bg, MoPalette.dark.bg);
    });

    test('没有动态色（Windows / 低版本）→ 固定色板', () {
      final ThemeController c = ThemeController();
      expect(_themePalette(c.lightTheme).bg, MoPalette.light.bg);
      expect(_themePalette(c.darkTheme).bg, MoPalette.dark.bg);
    });
  });

  group('旧设置迁移（theme_id + theme_dark → theme_mode）', () {
    Future<SharedPreferences> migrate(Map<String, Object> init) async {
      SharedPreferences.setMockInitialValues(init);
      await Repo.instance.migrateThemeMode();
      return SharedPreferences.getInstance();
    }

    test('开过夜间模式 → dark', () async {
      final SharedPreferences p = await migrate(<String, Object>{
        'theme_id': 1,
        'theme_dark': true,
      });
      expect(p.getString('theme_mode'), 'dark');
      expect(p.getBool('theme_dark'), isNull);
      expect(p.getInt('theme_id'), isNull);
    });

    test('没开夜间模式 → system（默认跟随系统）', () async {
      final SharedPreferences p = await migrate(<String, Object>{
        'theme_id': 2,
        'theme_dark': false,
      });
      expect(p.getString('theme_mode'), 'system');
    });

    test('新键优先：已有 theme_mode 时不被旧键覆盖', () async {
      final SharedPreferences p = await migrate(<String, Object>{
        'theme_mode': 'light',
        'theme_dark': true,
      });
      expect(p.getString('theme_mode'), 'light');
    });

    test('全新安装 → system', () async {
      final SharedPreferences p = await migrate(<String, Object>{});
      expect(p.getString('theme_mode'), 'system');
    });
  });

  test('MoColors.lerp：切换时直接换色板，不插出灰中间态', () {
    final MoColors a = MoColors(palette: MoPalette.light);
    final MoColors b = MoColors(palette: MoPalette.dark);
    expect(a.lerp(b, 0.2).palette, MoPalette.light);
    expect(a.lerp(b, 0.8).palette, MoPalette.dark);
    expect(a.copyWith().palette, MoPalette.light);
  });
}
