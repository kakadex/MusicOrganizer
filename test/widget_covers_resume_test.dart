import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/feature/covers/covers_progress.dart';

void main() {
  test('CoverJob.reset 保留续跑地址，forgetResume 才清', () {
    final CoverJob job = CoverJob(VFile(docId: 'a', name: 'a.mp3'));
    job.resumeUrl = 'https://example.com/cover.jpg';
    job.resumed = true;

    // reset 是「开始补封面」用的：要接着用续跑地址跳过联网，不能清掉
    job.reset();
    expect(job.resumeUrl, 'https://example.com/cover.jpg');
    expect(job.resumed, isTrue);

    // forgetResume 是「重新开始 / 再跑一次」用的：明确清掉续跑
    job.forgetResume();
    expect(job.resumeUrl, '');
    expect(job.resumed, isFalse);
  });
}
