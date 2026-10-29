import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/tag_fill.dart';
import 'package:musicorganizer/core/settings/settings_backup.dart';

Map<String, Object> sample() => <String, Object>{
      'recursive': true,
      'fn_weight': 20,
      'fp:title': TagFill.supplement,
      'ep:netease.0': 'https://m.example.com/ne',
      'ep_on:netease': false,
    };

void main() {
  test('键分类', () {
    expect(SettingsBackup.kindOf('recursive'), SettingsKind.boolKey);
    expect(SettingsBackup.kindOf('fn_weight'), SettingsKind.intKey);
    expect(SettingsBackup.kindOf('fp:title'), SettingsKind.fieldMode);
    expect(SettingsBackup.kindOf('ep:netease.0'), SettingsKind.endpointUrl);
    expect(SettingsBackup.kindOf('ep_on:netease'), SettingsKind.sourceOn);
    expect(SettingsBackup.isKnownKey('tree_uri'), isFalse);
    expect(SettingsBackup.isKnownKey('notif_asked'), isFalse);
    expect(SettingsBackup.kindOf('fp:nope'), isNull);
    expect(SettingsBackup.kindOf('ep_on:nope'), isNull);
    expect(SettingsBackup.kindOf('ep:nope.9'), isNull);
    expect(SettingsBackup.kindOf(''), isNull);
    expect(SettingsBackup.kindOf(null), isNull);
  });

  test('导出结构', () {
    final Map<String, Object> values = sample();
    values['tree_uri'] = 'content://should/not/appear';
    final String json = SettingsBackup.toJson(values, '2026-10-22 导出');
    expect(json.contains('"app": "MusicOrganizer"'), isTrue);
    expect(json.contains('"version": 1'), isTrue);
    expect(json.contains('"settings": {'), isTrue);
    expect(json.contains('"recursive": true'), isTrue);
    expect(json.contains('"fn_weight": 20'), isTrue);
    expect(json.contains('"ep:netease.0": "https://m.example.com/ne"'), isTrue);
    expect(json.contains('tree_uri'), isFalse);
    expect(json.contains('\\u5bfc') || json.contains('exportedAt'), isTrue);
    expect(json.indexOf('"ep:netease.0"') < json.indexOf('"fp:title"'), isTrue);
    expect(SettingsBackup.fromJson(json).ok, isTrue);
  });

  test('导出 → 导入 往返', () {
    final String json = SettingsBackup.toJson(sample(), 'stamp');
    final SettingsImport i = SettingsBackup.fromJson(json);
    expect(i.ok, isTrue);
    expect(i.count, sample().length);
    expect(i.values['recursive'], true);
    expect(i.values['fn_weight'], 20);
    expect(i.values['ep:netease.0'], 'https://m.example.com/ne');
    expect(i.values['ep_on:netease'], false);
    expect(i.values['fp:title'], TagFill.supplement);
    expect(i.warnings, isEmpty);
    expect(i.ignored, isEmpty);
    expect(i.summary().contains('可用设置 5 项'), isTrue);
  });

  test('容错：越界 / 非法地址 / 陌生键', () {
    const String json = '{"app":"MusicOrganizer","version":1,"settings":{'
        '"fn_weight":150,'
        '"fp:title":9,'
        '"ep:netease.0":"ftp://bad",'
        '"ep_on:qqmusic":"false",'
        '"unknown_key":1'
        '}}';
    final SettingsImport i = SettingsBackup.fromJson(json);
    expect(i.ok, isTrue);
    expect(i.values['fn_weight'], 100);
    expect(i.values['fp:title'], 2);
    expect(i.values.containsKey('ep:netease.0'), isFalse);
    expect(i.values['ep_on:qqmusic'], false);
    expect(i.ignored, contains('unknown_key'));
    expect(i.warnings.length, 3);
    expect(i.summary().contains('已修正 / 丢弃 3 项'), isTrue);
    expect(i.summary().contains('忽略不认识的键 1 个'), isTrue);

    final SettingsImport neg = SettingsBackup.fromJson(
        '{"app":"MusicOrganizer","settings":{"fn_weight":-5}}');
    expect(neg.values['fn_weight'], 0);
  });

  test('扁平格式与字符串化数值', () {
    const String json = '{"recursive":"true","fn_weight":"35","ep_on:kugou":"0"}';
    final SettingsImport i = SettingsBackup.fromJson(json);
    expect(i.ok, isTrue);
    expect(i.values['recursive'], true);
    expect(i.values['fn_weight'], 35);
    expect(i.values['ep_on:kugou'], false);
    expect(i.values.containsKey('app'), isFalse);
  });

  test('坏输入', () {
    expect(SettingsBackup.fromJson('').ok, isFalse);
    expect(SettingsBackup.fromJson(null).ok, isFalse);
    expect(SettingsBackup.fromJson('hello').ok, isFalse);
    expect(SettingsBackup.fromJson('[1,2]').ok, isFalse);
    expect(SettingsBackup.fromJson('{"a":1').ok, isFalse);
    final SettingsImport other = SettingsBackup.fromJson(
        '{"app":"OtherApp","settings":{"recursive":true}}');
    expect(other.ok, isFalse);
    expect(other.summary().contains('这不是'), isTrue);
    final SettingsImport wrong = SettingsBackup.fromJson(
        '{"app":"MusicOrganizer","settings":[1,2]}');
    expect(wrong.ok, isFalse);
  });

  test('恢复默认能覆盖逐字段写入策略', () {
    final Map<String, Object> d = SettingsBackup.defaults();
    // 默认值必须和界面用的那套一致：标题 / 艺术家只补空，其余不写
    expect(d['fp:title'], TagFill.supplement);
    expect(d['fp:artist'], TagFill.supplement);
    for (final String f in <String>['album', 'year', 'genre']) {
      expect(d['fp:$f'], TagFill.disabled, reason: '$f 的默认值不在表里');
    }
    // 已下线的字段（专辑艺术家 / 音轨）不再有默认值，也不参与策略
    expect(d.containsKey('fp:albumArtist'), isFalse);
    expect(d.containsKey('fp:track'), isFalse);

    // 用户手动改成「覆盖」：恢复默认时要能算进差异，否则点了恢复还是老样子
    final List<String> diff = SettingsBackup.diffFromDefaults(<String, Object?>{
      'fp:album': TagFill.overwrite,
    });
    expect(diff, contains('fp:album'));
    // 没存过的字段不算差异（新用户点恢复不该冒出一堆项）
    expect(SettingsBackup.diffFromDefaults(<String, Object?>{}), isEmpty);
  });
}
