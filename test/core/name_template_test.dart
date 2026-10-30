/// 文件名模板：校验与渲染（T-13）。
library;

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/cleanup/name_template.dart';
import 'package:musicorganizer/core/model/tags.dart';

void main() {
  Map<String, String> fields({String track = '7'}) {
    final Tags t = Tags();
    t.put('artist', '周杰伦');
    t.put('title', '晴天');
    t.put('album', '叶惠美');
    t.put('year', '2003');
    t.put('track', track);
    return NameTemplate.fields(t);
  }

  group('validate', () {
    test('合法模板', () {
      expect(NameTemplate.validate('{artist} - {title}'), isNull);
      expect(NameTemplate.validate('{track}. {title}'), isNull);
      expect(NameTemplate.validate('{artist}/{album}/{track:3}'), isNull);
      expect(NameTemplate.validate('{ext}'), isNull);
    });

    test('空模板 / 没有占位符', () {
      expect(NameTemplate.validate(''), isNotNull);
      expect(NameTemplate.validate('   '), isNotNull);
      expect(NameTemplate.validate('固定名字'), contains('占位符'));
    });

    test('拼错的占位符要说清是哪一个', () {
      final String? err = NameTemplate.validate('{atrist} - {title}');
      expect(err, contains('atrist'));
      expect(err, contains('不认识'));
    });

    test('括号不配对', () {
      expect(NameTemplate.validate('{artist - {title}'), contains('不配对'));
    });

    test('位数只对音轨有意义，且限 1~4', () {
      expect(NameTemplate.validate('{artist:3}'), contains('只有 {track}'));
      expect(NameTemplate.validate('{track:9}'), contains('1~4'));
      expect(NameTemplate.validate('{track:0}'), contains('1~4'));
      expect(NameTemplate.validate('{track:abc}'), contains('1~4'));
      expect(NameTemplate.validate('{track:2}'), isNull);
    });
  });

  group('render', () {
    test('音轨补零，可指定位数', () {
      expect(NameTemplate.render('{track}. {title}', fields(), '.mp3'),
          '07. 晴天.mp3');
      expect(NameTemplate.render('{track:3}. {title}', fields(), '.mp3'),
          '007. 晴天.mp3');
      expect(NameTemplate.render('{track:1}. {title}', fields(), '.mp3'),
          '7. 晴天.mp3');
    });

    test('音轨号带斜杠只取前一段', () {
      expect(NameTemplate.render('{track} - {title}', fields(track: '3/12'), '.flac'),
          '03 - 晴天.flac');
    });

    test('字段缺失时不留残渣分隔符', () {
      final Map<String, String> f = fields();
      f['album'] = '';
      expect(NameTemplate.render('{artist} - {album} - {title}', f, '.mp3'),
          '周杰伦 - 晴天.mp3');
    });

    test('{ext} 显式写了就不再追加', () {
      expect(NameTemplate.render('{title}.{ext}', fields(), '.mp3'), '晴天.mp3');
    });

    test('标签是繁体时，生成的文件名转成简体', () {
      final Tags t = Tags();
      t.put('artist', '張學友');
      t.put('title', '她來聽我的演唱會');
      t.put('album', '走過1999');
      final String name = NameTemplate.render(
          '{artist} - {title}', NameTemplate.fields(t), '.mp3');
      expect(name, '张学友 - 她来听我的演唱会.mp3');
      expect(NameTemplate.fields(t)['album'], '走过1999');
    });

    test('英文与数字原样保留', () {
      final Tags t = Tags();
      t.put('artist', 'Beyond');
      t.put('title', '光輝歲月');
      expect(NameTemplate.render('{artist} - {title}', NameTemplate.fields(t), '.flac'),
          'Beyond - 光辉岁月.flac');
    });
  });
}
