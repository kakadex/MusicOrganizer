import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/feature/lyrics_batch/lyrics_row_tile.dart';

void main() {
  test('LyricRow.reset 保留续跑标记，forgetResume 才清', () {
    final LyricRow row = LyricRow(VFile(docId: 'a', name: 'a.mp3'));
    row.resumed = true;

    // reset 是「获取歌词」用的：要接着用续跑结果跳过联网，不能清掉
    row.reset();
    expect(row.resumed, isTrue);

    // forgetResume 是「重新开始 / 重新获取」用的：明确清掉
    row.forgetResume();
    expect(row.resumed, isFalse);
  });
}
