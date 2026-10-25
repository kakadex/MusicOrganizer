// flutter_test 转出的 test_api 也有个 Tags（测试标记），这里隐藏掉避免与模型 Tags 撞名。
import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/match/tag_fill.dart';
import 'package:musicorganizer/core/match/tag_plan.dart';
import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile vf(String id) => VFile(docId: id, name: '$id.mp3');

Candidate cand({
  String title = '示例歌名',
  String artist = '示例歌手',
  String album = '示例专辑',
  String year = '2020',
  String track = '',
  String genre = '',
  String source = 'netease',
  double confidence = 0.9,
  int merged = 1,
  String sources = '',
}) => Candidate()
  ..title = title
  ..artist = artist
  ..album = album
  ..year = year
  ..track = track
  ..genre = genre
  ..source = source
  ..confidence = confidence
  ..merged = merged
  ..sources = sources;

Tags before({
  String title = '',
  String artist = '',
  String album = '',
  String year = '',
  String track = '',
  String genre = '',
}) {
  final Tags t = Tags();
  t.put('title', title);
  t.put('artist', artist);
  t.put('album', album);
  t.put('year', year);
  t.put('track', track);
  t.put('genre', genre);
  return t;
}

List<String> keysOf(FilePlan p) =>
    p.fields.map((PlanField f) => f.key).toList();

void main() {
  test('三态：只补空不动已有值，覆盖才改写，禁用字段不进计划', () {
    final Tags b = before(title: '旧标题', artist: '示例歌手');

    final FilePlan supplement =
        TagPlan.buildFor(file: vf('a'), before: b, candidate: cand());
    expect(keysOf(supplement), <String>['album', 'year']);
    expect(supplement.fields.first.mode, TagFill.supplement);
    expect(supplement.hasChange, isTrue);

    final FilePlan overwrite =
        TagPlan.buildFor(file: vf('a'), before: b, candidate: cand(), overwrite: true);
    expect(overwrite.toUpdates(),
        <String, String>{'title': '示例歌名', 'album': '示例专辑', 'year': '2020'});
    expect(overwrite.fields.first.mode, TagFill.overwrite);

    final Map<String, int> modes = TagFill.defaultModes(false)
      ..['album'] = TagFill.disabled;
    final FilePlan disabled =
        TagPlan.buildFor(file: vf('a'), before: b, candidate: cand(), modes: modes);
    expect(keysOf(disabled), <String>['year']);
  });

  test('候选字段为空时不产生变更', () {
    final FilePlan p = TagPlan.buildFor(
      file: vf('b'),
      before: before(title: '示例歌名', artist: '示例歌手'),
      candidate: cand(title: '', artist: '', album: '', year: ''),
      overwrite: true,
    );
    expect(p.fields, isEmpty);
    expect(p.hasChange, isFalse);
    expect(p.toUpdates(), isEmpty);
  });

  test('toUpdates 只导出勾选且真变了的字段', () {
    final FilePlan p =
        TagPlan.buildFor(file: vf('c'), before: before(), candidate: cand());
    expect(p.fields.every((PlanField f) => f.changed), isTrue);
    expect(p.toUpdates().length, keysOf(p).length);

    p.fields.firstWhere((PlanField f) => f.key == 'album').accepted = false;
    final Map<String, String> u = p.toUpdates();
    expect(u.containsKey('album'), isFalse);
    expect(u['title'], '示例歌名');
    expect(p.hasChange, isTrue);

    for (final PlanField f in p.fields) {
      f.accepted = false;
    }
    expect(p.hasChange, isFalse);
    expect(p.toUpdates(), isEmpty);
  });

  test('整首取消勾选后不进入待写入集合', () {
    final List<FilePlan> plans = <FilePlan>[
      TagPlan.buildFor(file: vf('x'), before: before(), candidate: cand()),
      TagPlan.buildFor(file: vf('y'), before: before(), candidate: cand())
        ..selected = false,
    ];
    expect(TagPlan.onlySelected(plans).map((FilePlan p) => p.file.docId),
        <String>['x']);
  });

  test('低置信标记与 note 文案', () {
    final FilePlan low = TagPlan.buildFor(
      file: vf('d'),
      before: before(),
      candidate: cand(confidence: 0.3, source: 'qqmusic'),
    );
    expect(low.lowConfidence, isTrue);
    expect(low.note, '来源：QQ 音乐；低置信，建议人工确认');

    // 阈值是「低于」，正好等于不算低置信。
    final FilePlan ok = TagPlan.buildFor(
      file: vf('e'),
      before: before(),
      candidate: cand(confidence: TagPlan.lowConfidenceThreshold, source: 'kugou'),
    );
    expect(ok.lowConfidence, isFalse);
    expect(ok.note, '来源：酷狗');
  });

  test('多源一致时 note 带来源数与名称', () {
    final FilePlan p = TagPlan.buildFor(
      file: vf('f'),
      before: before(),
      candidate: cand(merged: 3, sources: '网易云 / QQ 音乐 / 酷狗'),
    );
    expect(p.note, '3 家一致：网易云 / QQ 音乐 / 酷狗');

    final FilePlan low = TagPlan.buildFor(
      file: vf('g'),
      before: before(),
      candidate: cand(merged: 2, sources: '酷我 / 咪咕', confidence: 0.2),
    );
    expect(low.note, '2 家一致：酷我 / 咪咕；低置信，建议人工确认');
  });

  test('summarize 四类计数正确', () {
    final Tags full = before(
      title: '示例歌名',
      artist: '示例歌手',
      album: '示例专辑',
      year: '2020',
      track: '1',
      genre: '示例流派',
    );
    final List<FilePlan> plans = <FilePlan>[
      TagPlan.buildFor(file: vf('p1'), before: before(), candidate: cand()),
      TagPlan.buildFor(
          file: vf('p2'), before: before(), candidate: cand(confidence: 0.2)),
      TagPlan.buildFor(file: vf('p3'), before: full, candidate: cand()),
      TagPlan.buildFor(file: vf('p4'), before: before()),
    ];
    expect(TagPlan.summarize(plans),
        '共 4 首，待写入 2 首，低置信 1 首，无变更 2 首');
  });

  test('批量构建：无候选的文件给空计划且不报错', () {
    final List<FilePlan> plans = TagPlan.build(
      files: <VFile>[vf('m1'), vf('m2')],
      before: <String, Tags>{'m1': before()},
      chosen: <String, Candidate>{'m1': cand()},
    );
    expect(plans.length, 2);
    expect(plans[0].hasChange, isTrue);
    expect(plans[1].hasChange, isFalse);
    expect(plans[1].candidate, isNull);
    expect(plans[1].fields, isEmpty);
    expect(plans[1].note, '无候选');
    expect(plans[1].toUpdates(), isEmpty);
  });
}
