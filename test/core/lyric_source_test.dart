import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/lyrics/krc.dart';
import 'package:musicorganizer/core/model/lyric_hit.dart';
import 'package:musicorganizer/core/source/endpoints.dart';
import 'package:musicorganizer/core/source/lyric_kugou.dart';
import 'package:musicorganizer/core/source/lyric_lrclib.dart';
import 'package:musicorganizer/core/source/lyric_netease.dart';
import 'package:musicorganizer/core/source/lyric_ovh.dart';
import 'package:musicorganizer/core/source/lyric_qq.dart';
import 'package:musicorganizer/core/source/lyric_source.dart';
import 'package:musicorganizer/core/source/tag_source.dart';

/// 带时间轴的示例歌词（中性占位，不写真人真曲）。
const String sampleLrc = '[00:12.00]示例歌词第一行\n[00:16.50]示例歌词第二行';

/// 示例 KRC 明文（逐字三元组），喂给酷狗源的 KRC 分支。
const String sampleKrc = '[ti:示例歌名]\n[ar:示例歌手]\n[offset:0]\n[1000,2000]<0,300,0>示<300,300,0>例<600,400,0>歌<1000,200,0>名';

/// 网易云搜索夹具：一条候选（带 id 与毫秒时长）。
const String neSearch = '{"result":{"songs":[{"id":100001,"name":"示例歌名","duration":203000,"artists":[{"name":"示例歌手"}]}]}}';

/// 酷狗搜索夹具：一条候选（带 id 与 accesskey）。
const String kgSearch = '{"candidates":[{"id":"KID1","accesskey":"AK1","song":"示例歌名","singer":"示例歌手","duration":203000}]}';

/// 查询：中性占位（示例歌手 / 示例歌名 / 示例专辑）。
LyricQuery query() =>
    LyricQuery(title: '示例歌名', artist: '示例歌手', album: '示例专辑', duration: 203);

/// 注入式 JSON 回调：按 url 取夹具，不真联网。
JsonFetcher jsonOf(Object? Function(String url, Map<String, String>? params) fn) =>
    (String url, Map<String, String>? params) async => fn(url, params);

/// 注入式文本回调：按 url 取夹具，不真联网。
TextFetcher textOf(String? Function(String url, Map<String, String>? params) fn) =>
    (String url, Map<String, String>? params) async => fn(url, params);

/// 恒定返回同一份 JSON 夹具的回调；传 null 表示这家没返回东西。
JsonFetcher jsonConst(String? payload) =>
    jsonOf((String url, Map<String, String>? p) => payload == null ? null : jsonDecode(payload));

/// 按算法逆推加密：zlib 压缩 → 逐字节 XOR → 加 krc1 头 → base64。
String encryptKrc(String plain) {
  final List<int> z = zlib.encode(utf8.encode(plain));
  final List<int> body = <int>[...Krc.magic];
  for (int i = 0; i < z.length; i++) {
    body.add(z[i] ^ Krc.key[i % Krc.key.length]);
  }
  return base64Encode(body);
}

void main() {
  test('LRCLIB 精确查询命中并解析出同步歌词', () async {
    final List<LyricHit> hits = await LrclibSource().search(query(),
        json: jsonConst('{"trackName":"示例歌名","artistName":"示例歌手","albumName":"示例专辑","duration":203,'
            '"syncedLyrics":"[00:12.00]示例歌词第一行\\n[00:16.50]示例歌词第二行","plainLyrics":"示例歌词第一行"}'));
    expect(hits.length, 1);
    expect(hits.first.source, 'lrclib');
    expect(hits.first.synced, sampleLrc);
    expect(hits.first.duration, 203);
    expect(hits.first.translation, '');
  });

  test('LRCLIB 精确查询无同步歌词时回退模糊搜索', () async {
    final List<String> urls = <String>[];
    final List<LyricHit> hits = await LrclibSource().search(query(),
        json: jsonOf((String url, Map<String, String>? p) {
      urls.add(url);
      return urls.length == 1
          ? jsonDecode('{"trackName":"示例歌名","plainLyrics":"示例歌词"}')
          : jsonDecode('[{"syncedLyrics":"[00:12.00]示例歌词第一行"}]');
    }));
    expect(urls, <String>[Endpoints.urlOf('lrclib', 0), Endpoints.urlOf('lrclib', 1)]);
    expect(hits.length, 2);
    expect(hits.first.synced, '[00:12.00]示例歌词第一行'); // 同步歌词排前面
  });

  test('LRCLIB 空结果与畸形输入都返回空列表', () async {
    expect(await LrclibSource().search(query(), json: jsonConst(null)), isEmpty);
    expect(await LrclibSource().search(query(), json: jsonConst('"坏了"')), isEmpty);
    expect(await LrclibSource().search(query(), json: jsonConst('{"trackName":"示例歌名"}')),
        isEmpty);
    expect(await LrclibSource().search(LyricQuery(), json: jsonConst('{}')), isEmpty);
  });

  test('网易云 搜索 + 取歌词：译文轨与 lv/kv/tv 参数', () async {
    const String lyric = '{"lrc":{"lyric":"[00:12.00]示例歌词第一行\\n[00:16.50]示例歌词第二行"},"tlyric":{"lyric":"[00:12.00]示例译文第一行"}}';
    final List<Map<String, String>?> params = <Map<String, String>?>[];
    final List<LyricHit> hits = await NeteaseLyricSource().search(query(),
        json: jsonOf((String url, Map<String, String>? p) {
      params.add(p);
      return jsonDecode(p?['id'] == null ? neSearch : lyric);
    }));
    expect(params.last?['id'], '100001');
    // lv/kv/tv 必须都是 -1，否则译文轨整段为空
    expect(<String?>[params.last?['lv'], params.last?['kv'], params.last?['tv']],
        <String>['-1', '-1', '-1']);
    expect(hits.length, 1);
    expect(hits.first.source, 'netease');
    expect(hits.first.synced, sampleLrc);
    expect(hits.first.translation, '[00:12.00]示例译文第一行');
  });

  test('网易云 无搜索结果 / 歌词为空都返回空列表', () async {
    expect(await NeteaseLyricSource().search(query(), json: jsonConst(null)), isEmpty);
    expect(await NeteaseLyricSource().search(query(), json: jsonConst('{"result":{}}')),
        isEmpty);
    final List<LyricHit> hits = await NeteaseLyricSource().search(query(),
        json: jsonOf((String url, Map<String, String>? p) =>
            jsonDecode(p?['id'] == null ? neSearch : '{"lrc":{"lyric":"  "}}')));
    expect(hits, isEmpty);
  });

  test('QQ 音乐 JSONP + base64 歌词解码，译文反转义', () async {
    const String search = '{"req":{"data":{"body":{"song":{"list":[{"mid":"MID001","name":"示例歌名","interval":203,"singer":[{"name":"示例歌手"}]}]}}}}}';
    // 接口偶尔无视 nobase64=1 仍返 base64，响应还常被 JSONP 包裹
    final String body = jsonEncode(<String, Object>{
      'lyric': base64Encode(utf8.encode(sampleLrc)),
      'trans': '[00:12.00]It&apos;s a sample line',
    });
    final List<Map<String, String>?> params = <Map<String, String>?>[];
    final List<LyricHit> hits = await QqLyricSource().search(query(),
        json: jsonConst(search),
        text: textOf((String url, Map<String, String>? p) {
          params.add(p);
          return 'MusicJsonCallback($body);';
        }));
    expect(params.first?['songmid'], 'MID001');
    expect(params.first?['nobase64'], '1');
    expect(hits.length, 1);
    expect(hits.first.source, 'qqmusic');
    expect(hits.first.synced, sampleLrc);
    expect(hits.first.translation, contains("It's a sample line"));
  });

  test('QQ 音乐 无搜索结果 / 响应不是 JSON 都返回空列表', () async {
    const String search = '{"req":{"data":{"body":{"song":{"list":[{"mid":"MID001"}]}}}}}';
    expect(await QqLyricSource().search(query(),
        json: jsonConst(null), text: textOf((String u, Map<String, String>? p) => 'x')),
        isEmpty);
    final List<LyricHit> hits = await QqLyricSource().search(query(),
        json: jsonConst(search),
        text: textOf((String u, Map<String, String>? p) => '<html>502</html>'));
    expect(hits, isEmpty);
    expect(await QqLyricSource().search(LyricQuery(), json: jsonConst(search)), isEmpty);
  });

  test('lyrics.ovh 按艺人 / 歌名取到纯文本', () async {
    final List<String> urls = <String>[];
    final List<LyricHit> hits = await OvhLyricSource().search(query(),
        json: jsonOf((String url, Map<String, String>? p) {
      urls.add(url);
      return jsonDecode('{"lyrics":"示例歌词第一行\\n示例歌词第二行"}');
    }));
    expect(hits.length, 1);
    expect(hits.first.source, 'lyricsovh');
    expect(hits.first.plain, '示例歌词第一行\n示例歌词第二行');
    expect(urls.single, startsWith(Endpoints.urlOf('lyric_ovh', 0)));
    expect(urls.single,
        endsWith('${Uri.encodeComponent('示例歌手')}/${Uri.encodeComponent('示例歌名')}'));
  });

  test('lyrics.ovh 空歌词 / 畸形响应；艺人缺失用 unknown 占位', () async {
    expect(await OvhLyricSource().search(query(), json: jsonConst('{"lyrics":"   "}')),
        isEmpty);
    expect(await OvhLyricSource().search(query(), json: jsonConst('"坏了"')), isEmpty);
    final List<String> urls = <String>[];
    final List<LyricHit> hits = await OvhLyricSource()
        .search(LyricQuery(title: '示例歌名'), json: jsonOf((String url, Map<String, String>? p) {
      urls.add(url);
      return jsonDecode('{"lyrics":"示例歌词"}');
    }));
    expect(hits.length, 1);
    expect(urls.single, endsWith('/unknown/${Uri.encodeComponent('示例歌名')}'));
  });

  test('酷狗 KRC 解密后转成只带行时间轴的 LRC', () async {
    final String enc = encryptKrc(sampleKrc);
    final List<String> fmts = <String>[];
    final List<LyricHit> hits = await KugouLyricSource().search(query(),
        json: jsonOf((String url, Map<String, String>? p) {
      if (url == Endpoints.urlOf('lyric_kugou', 0)) return jsonDecode(kgSearch);
      fmts.add(p?['fmt'] ?? '');
      return jsonDecode('{"content":"$enc"}');
    }));
    expect(fmts, <String>['krc']);
    expect(hits.length, 1);
    expect(hits.first.source, 'kugou');
    expect(hits.first.synced, contains('[00:01.00]示例歌名'));
    expect(hits.first.synced, isNot(contains('<')));
  });

  test('酷狗 KRC 解不出时降级为明文 LRC（base64）', () async {
    final List<String> fmts = <String>[];
    final List<LyricHit> hits = await KugouLyricSource().search(query(),
        json: jsonOf((String url, Map<String, String>? p) {
      if (url == Endpoints.urlOf('lyric_kugou', 0)) return jsonDecode(kgSearch);
      fmts.add(p?['fmt'] ?? '');
      final String content =
          p?['fmt'] == 'krc' ? '坏数据' : base64Encode(utf8.encode(sampleLrc));
      return jsonDecode('{"content":"$content"}');
    }));
    expect(fmts, <String>['krc', 'lrc']);
    expect(hits.length, 1);
    expect(hits.first.source, 'kugou');
    expect(hits.first.synced, sampleLrc);
  });

  test('酷狗 无候选 / 空 content 返回空列表', () async {
    expect(await KugouLyricSource().search(query(), json: jsonConst('{"candidates":[]}')),
        isEmpty);
    expect(await KugouLyricSource().search(query(), json: jsonConst(null)), isEmpty);
    final List<LyricHit> hits = await KugouLyricSource().search(query(),
        json: jsonOf((String url, Map<String, String>? p) => jsonDecode(
            url == Endpoints.urlOf('lyric_kugou', 0) ? kgSearch : '{"content":""}')));
    expect(hits, isEmpty);
  });
}
