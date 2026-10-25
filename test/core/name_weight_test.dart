import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/name_weight.dart';

void main() {
  test('权重 0% —— 只信已有标签', () {
    expect(NameWeight.pick('文件歌名', '标签歌名', 0.0), '标签歌名');
    expect(NameWeight.pick('文件歌名', '', 0.0), '文件歌名');
  });

  test('权重 100% —— 只信文件名', () {
    expect(NameWeight.pick('文件歌名', '标签歌名', 1.0), '文件歌名');
    expect(NameWeight.pick('', '标签歌名', 1.0), '标签歌名');
  });

  test('50% 分界线（>=50 以文件名为准）', () {
    expect(NameWeight.pick('文件歌名', '标签歌名', 0.49), '标签歌名');
    expect(NameWeight.pick('文件歌名', '标签歌名', 0.5), '文件歌名');
  });

  test('备选值', () {
    expect(NameWeight.pickSecondary('文件歌名', '标签歌名', 0.2), '文件歌名');
    expect(NameWeight.pickSecondary('文件歌名', '标签歌名', 0.8), '标签歌名');
    expect(NameWeight.pickSecondary('同名', '同名', 0.2), '');
  });

  test('百分比换算与越界收缩', () {
    expect((NameWeight.fromPercent(30) - 0.30).abs(), lessThan(1e-9));
    expect(NameWeight.fromPercent(-5), 0.0);
    expect(NameWeight.fromPercent(180), 1.0);
    expect((NameWeight.clamp(double.nan) - NameWeight.fromPercent(NameWeight.defaultPercent)).abs(),
        lessThan(1e-9));
  });

  // 旧 NameWeightTest 的第 6~9 节测的是 TaskControl（任务暂停/取消），
  // 该类属 T04 模型层，本次 T02 未移植，相关用例随 T04 补回。
}
