import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/lyrics/zh.dart';

void main() {
  test('基本字', () {
    expect(Zh.toSimplified('愛'), '爱');
    expect(Zh.toSimplified('們'), '们');
    expect(Zh.toSimplified('說'), '说');
    expect(Zh.toSimplified('時'), '时');
    expect(Zh.toSimplified('間'), '间');
    expect(Zh.toSimplified('願'), '愿');
    expect(Zh.toSimplified('妳好'), '你好');
    expect(Zh.toSimplified('牠'), '它');
    expect(Zh.toSimplified('臺北'), '台北');
    expect(Zh.toSimplified('心裡'), '心里');
    expect(Zh.toSimplified('乾淨'), '干净');
    expect(Zh.toSimplified('幾個'), '几个');
    expect(Zh.toSimplified('什麼'), '什么');
    expect(Zh.toSimplified('為什麼'), '为什么');
  });

  test('整句歌词', () {
    expect(Zh.toSimplified('我們說好的幸福呢'), '我们说好的幸福呢');
    expect(Zh.toSimplified('我愛你\n你是否也愛我\n別讓我一個人'),
        '我爱你\n你是否也爱我\n别让我一个人');
    expect(Zh.toSimplified('我看著你\n我看著你（譯）'), '我看着你\n我看着你（译）');
    expect(Zh.toSimplified(''), '');
    expect(Zh.toSimplified(null), '');
  });

  test('时间轴与格式', () {
    expect(Zh.toSimplified('[00:12.34]我們相愛'), '[00:12.34]我们相爱');
    expect(Zh.toSimplified('[00:01.00][01:20.50]愛'), '[00:01.00][01:20.50]爱');
    expect(Zh.toSimplified('[offset:500]\n愛'), '[offset:500]\n爱');
    expect(Zh.toSimplified('「愛」，。！？'), '「爱」，。！？');
  });

  test('一对多的字', () {
    expect(Zh.toSimplified('著名歌手'), '著名歌手');
    expect(Zh.toSimplified('著作權'), '著作权');
    expect(Zh.toSimplified('看著你'), '看着你');
    expect(Zh.toSimplified('睡著了'), '睡着了');
    expect(Zh.toSimplified('笑著說'), '笑着说');
    expect(Zh.toSimplified('乾隆'), '乾隆');
    expect(Zh.toSimplified('乾坤'), '乾坤');
    expect(Zh.toSimplified('乾燥'), '干燥');
    expect(Zh.toSimplified('藉口'), '借口');
    expect(Zh.toSimplified('憑藉'), '凭借');
    expect(Zh.toSimplified('藉此'), '借此');
    expect(Zh.toSimplified('慰藉'), '慰藉');
    expect(Zh.toSimplified('狼藉'), '狼藉');
    expect(Zh.toSimplified('宮商角徵羽'), '宫商角徵羽');
  });

  test('日文不转', () {
    const String ja = '君の名前を呼ぶ 愛してる';
    expect(Zh.toSimplified(ja), ja);
    const String jaKanji = '日本語の歌詞、東京の夜';
    expect(Zh.toSimplified(jaKanji), jaKanji);
    expect(Zh.isJapanese('あいう'), isTrue);
    expect(Zh.isJapanese('アイウ'), isTrue);
    expect(Zh.isJapanese('我們相愛'), isFalse);
  });

  test('不该动的', () {
    expect(Zh.toSimplified('我们相爱'), '我们相爱');
    expect(Zh.toSimplified('Love Me Tender 2026'), 'Love Me Tender 2026');
    expect(Zh.toSimplified('100% - 3.14 (x)'), '100% - 3.14 (x)');
    expect(Zh.toSimplified('愛你 ❤🎵'), '爱你 ❤🎵');
    expect(Zh.toSimplified('I love 你 我愛你'), 'I love 你 我爱你');
    expect(Zh.toSimplified('\n\n'), '\n\n');
  });

  test('幂等与覆盖', () {
    const String trad = '我們說好不分離，要一直走到最後，看細水長流。';
    final String once = Zh.toSimplified(trad);
    expect(Zh.toSimplified(once), once);
    expect(Zh.hasTraditional(once), isFalse);
    expect(Zh.hasTraditional(trad), isTrue);
    expect(Zh.hasTraditional('我们相爱的故事'), isFalse);
    expect(once.length, greaterThanOrEqualTo(trad.length - 2));
  });

  test('高频字覆盖 20/20', () {
    const List<List<String>> sample = <List<String>>[
      ['愛', '爱'], ['戀', '恋'], ['夢', '梦'], ['願', '愿'], ['淚', '泪'],
      ['傷', '伤'], ['溫', '温'], ['柔', '柔'], ['時', '时'], ['間', '间'],
      ['記', '记'], ['憶', '忆'], ['聲', '声'], ['聽', '听'], ['遠', '远'],
      ['邊', '边'], ['誰', '谁'], ['讓', '让'], ['給', '给'], ['變', '变'],
    ];
    for (final List<String> p in sample) {
      expect(Zh.toSimplified(p[0]), p[1], reason: '${p[0]} -> ${p[1]}');
    }
  });
}
