/// 标签匹配的「多家结果交叉验证」回归：
/// 同一首歌被两家以上同时命中时，预览里应标出「N 家一致」。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/match/batch_memory.dart';
import 'package:musicorganizer/core/match/tag_plan.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/scan/scanner.dart';
import 'package:musicorganizer/core/source/tag_source.dart';
import 'package:musicorganizer/core/tag/id3.dart';
import 'package:musicorganizer/core/task/match_runner.dart';
import 'package:musicorganizer/core/tx/journal.dart';
import 'package:musicorganizer/core/tx/tag_transaction.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mo_cross_');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 两个源给同一首歌，其余源空返回。
  JsonFetcher twoSourcesAgree() =>
      (String url, Map<String, String>? params) async {
        if (url.contains('music.163.com')) {
          return <String, Object?>{
            'result': <String, Object?>{
              'songs': <Object?>[
                <String, Object?>{
                  'name': '晴天',
                  'artists': <Object?>[
                    <String, Object?>{'name': '周杰伦'},
                  ],
                  'duration': 269000,
                },
              ],
            },
          };
        }
        if (url.contains('y.qq.com')) {
          return <String, Object?>{
            'req': <String, Object?>{
              'data': <String, Object?>{
                'body': <String, Object?>{
                  'song': <String, Object?>{
                    'list': <Object?>[
                      <String, Object?>{
                        'name': '晴天',
                        'singer': <Object?>[
                          <String, Object?>{'name': '周杰伦'},
                        ],
                        'interval': '269',
                      },
                    ],
                  },
                },
              },
            },
          };
        }
        return <String, Object?>{};
      };

  test('两家同时命中 → 预览标出「2 家一致」', () async {
    final DesktopFileStore store = DesktopFileStore();
    store.addRoot(dir.path);
    Uint8List data = Uint8List.fromList(List<int>.filled(2048, 0xFF));
    data = Id3.rewrite(data, <String, String>{'title': '晴天', 'artist': '周杰伦'});
    await File('${dir.path}/a.mp3').writeAsBytes(data);
    final VFile rootDir = VFile(docId: dir.path, name: 'root', dir: true);
    final WalkResult walk = await Scanner.scanMusicFiles(store, rootDir);
    final VFile a = walk.files.single;
    final Journal journal = Journal(File('${dir.path}/journal.jsonl'));
    final TagTransaction tx = TagTransaction(store: store, journal: journal);
    final BatchMemory memory = BatchMemory.open(dir, 'tags');
    final MatchRunner runner = MatchRunner(store: store, tx: tx, memory: memory);

    final List<FilePlan> plans =
        await runner.match(<VFile>[a], fetch: twoSourcesAgree());
    expect(plans.length, 1);
    expect(plans.single.candidate?.merged, 2);
    expect(plans.single.note, contains('家一致'));
  });
}
