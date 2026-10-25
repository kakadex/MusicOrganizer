import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/lyrics/krc.dart';

/// 真实线上样本：旧 tools/fixtures/krc_real.b64 的内容，原样搬成 Dart 常量。
///
/// 用它回归「krc1 头 + 16 字节密钥 XOR + zlib」这条链路 —— 旧版 v0.1.41 用错
/// （8 字节）密钥时，正是这段样本解不开。断言只校验结构，不写具体曲目信息。
const String realKrcBase64 =
      'a3JjMTjbJCCTXCmSRKjKBNZkvHCs8pfIK/b8Vv5WAEWfQ8Q/6t1TnpIUQX/g1CkYRvYbbchjxTfD'
      'NtZhJ1TKTFSpE5pWut/CqYxqQ7z1iHO1LxJWqyscjZn/kfpGvbbSsD1Zdjy/v8zlJd+6FqEG27Ap'
      'v6+WqM8acIwI9S3G3cBVFZGynr6BtKikG7ntv87TMD31FvqxkJ2y1csZqk7A3x+wmUy+oD5Jp9Yb'
      'OKlC4szmSJ1NFYUmxMXmz47sycf4Jx79zYrg0hg5bZ/j39kfAiAc/yZ1pAiCqk5achwsIvITLalF'
      'UlJeYmKMj6uqb03ZXX0EOPcgqFaoglwhMn1i2zZnoR/5P+fLp06SDjvW4swXzjL3/JQfNihHfmbd'
      'zlPcE1px6t/FnNKbPSEXF/r71az7Qdb6cJLTnLr/pNa+vl+yP586aNSmyEiN1n/+V7XaROZNlrCa'
      'tlhohCZt28bkmjrxrYY9fpLzFMvAOmHNYwrR/636/X6CVUGe7OSsb208KjdDl+1e0n/NJdL1q1dW'
      'TmVWcnD/85mbr8DLPGJ5247bKxJnEZf/5iB8uPcJdvc6mBGWhr6yZY558yuhgChAt2OvwJyHsmMP'
      'NHNiyIFJR2nXsReUl34GEZJmYtiOrFpv6dHJ1DzOiqPLewdavDz08xQnVd4wGJHPcYgg6LeLzch1'
      '5IG/cJuBhgnzr0oq+devVef5N+znQyM+vXPoACbqxDLSMSsn5DsQqI0U2KOiPaYFtRkPje5Bx6oQ'
      'pSBx/wD5xHKYYHBMqFFdunBjaL9atbFiY8FK/VbWehH+I7jrIMaJzNeKypkBA3mLfOUFtfrcko/2'
      '3ez2RXJhhzIdPmI67Sux2jAoNfwNYjfF4GbB1rmTVZWMPykByyLbeY+2jdkaRjTjcuwPa2U4cDyq'
      'v+VoODkpDi09uxshggZ+G+1XsBhp6quNhVVJYSvdDKF4MhrPNdGOPjp9ynxOe0Q8Nacrj7bV9HGy'
      'ZyP95uCc+SvM5CHcsZRknlA+u2BQLgY9KIaSTRTuo0T0VGv2cc6WE4c8jCyfRO+QXJpsBVrgFuIu'
      'xldNHFD2OU24hYeLSdDDEM9GgUDdn1uPZyL60dn1tJ1yGcq9HSKnkkAZ9jw8SQh7ra/4BJJZs1MD'
      'a65WA8sscC2App1D6p5evXgr5vRWctNjFxXzEGnEzB+nQxfPc3TpWp+K6yb3wh26abHSMhG5G6rW'
      'g7IleoDUPCsfM0DCOzWZXGxa3gL3R5ibpNGevUj2Oxig0TZ1fUaF1rxvP56gNp0pDTOEnWdLoWag'
      '6xC4rVJSBnSaCxqJ9dx1e30l8qaRc0ut8ZT0M2d1k9J/W6nstv8t9/NiABf1sOwiYg+GK/52Y41/'
      'zEZoS4w48w+y48JZV7MU2jiu76HzC1myecNT504nNJrov0YoiEvjcXCnLyWv+DenMmF2g3NM7TPa'
      'nxSntdiijl9c+bvtgknOFM2E85pEc68TubSfCcke+X8za65v3FOCAcKpej6VJDC21WyMcJdubLSN'
      'swAt/M+g7YS4H9kPb52FG69+u/sINIcayqC2vrZRtIs8KKfrlBYW51QYUXhPtwW8ZmgzTAFKHskX'
      'sDWll7u8L/6XyUOafAnOyXHFTD6XOs8crIE8lIMN9lhSAWCWDNJQR9zQ+rnXd6dwwAUEjDDrevWs'
      'bjhuLDDIh9T01Bm6YfKXz+YO/msEHGSOnQNA5NjbBi8lPfAz1sLwVxiuwIFDbfn2BgYi4FgRzeOJ'
      'kTWdglC2nacCJb1qRh0Bob7vsHJxLkCao9AlBkghe6xBUppuKedXK7BVVnTDGNw3U0/vj+NlIYap'
      'dv5ltxWH0kN82RHs/PPknsq8Hr79gRpOoiGMyq0efJqYRP+CsDfHKOdSCmnEXEWUXnUQlNZVJPka'
      '2xT0A+FKHUSU5WwW1ueLT5Ux8sL4wemem9EdsWWVc260v9P3m171OpJLJdTXINRq1oQSV5u0BTek'
      'lk6Q6kBocYKNTW3Ce1gIDXniEaWMowuYAhgr/WlITwRPIY7LdbAcWAWeU9caj2rPMJ5RWbqpp+Np'
      'xE1BleQMOaR8B3M8RrAySgRVZV4fMZTrigyCXkh4jleBPhzzPlFqdTDwBtl8z9eA12kaPDdl0z2Q'
      'Iy/Dl8oGJd4v+MXsCmAhAFCGbwOZe801PKL/w6igfiTyTNWbGTk2GjgtOKYVkFeGGvFCK1ywgPuB'
      'IlaAkp6D1tiYnCmG2XPgZE0dEKJKhbdKIvTABzjO2sD+BKoNxsoNvw0ssAtZ9z1dgTPEmRB27Llt'
      'WMcIEP2z7oAvrnm74QIyfwu3j41HlepPojB+sdz1x/fy55fRH8gtNSwYvxEWWGjkTCmQDn8C02cD'
      'tO6jNkqY9XTp11Lb0sg3YGGFixl4ZQNbVsIF0PsqwPHOVgTEjT1FB+NEG8UwRQkDJ2mV1FLEg/T9'
      '+Igv3djDPmGBf9AiAkoGPNbyyzj6zin5gq3zzhkTtd604qSGQ268M8pxHWz7T7kVkdN44JERJcZL'
      'o1Cm+P0hZEyEqlloFKgQ7XFXzmFv2njp21F3o2foF1vzYOMajIVQwfSs+pg7CFVAQJGKBV8TpO8J'
      'WXZ84+HbAkHuwrE9NgZL3mV46nrqm1AwV4dLtWn8cJrKQH04+SWB0T3pUeKEIx2QzMA+rmf1ILF8'
      'Kji2sM09ZZhRpMIRdpVTCFd5oSxEuNmsAASd+zXBtEawHyUfMQa8Fto96oCU2ZfWkYcqjkNxjRG1'
      'rgXyjkfTz8Y1PpqJf7P7c7uy1XjduMCjOSkRJyWQs8w1JJlwET/toZJDZWUx2ha+flFJWHKHyeQq'
      'YpmSZKadecavRfUpOrH/LrbxADDdMyBiRw==';

/// 自造样本的明文 KRC（中性占位，不写真人真曲）。
const String sampleKrc = '[ti:示例歌名]\n'
    '[ar:示例歌手]\n'
    '[offset:0]\n'
    '[1000,2000]<0,300,0>示<300,300,0>例<600,400,0>歌<1000,200,0>名\n'
    '[3000,1500]<0,200,0>第<200,250,0>二<450,300,0>行';

/// 按算法逆推加密：zlib 压缩 → 逐字节 XOR → 加 krc1 头 → base64。
String encryptSample(String plain) {
  final List<int> z = zlib.encode(utf8.encode(plain));
  final List<int> body = <int>[...Krc.magic];
  for (int i = 0; i < z.length; i++) {
    body.add(z[i] ^ Krc.key[i % Krc.key.length]);
  }
  return base64Encode(body);
}

void main() {
  group('KRC 解密', () {
    test('真实线上样本能解开', () {
      expect(Krc.looksEncoded(realKrcBase64), isTrue);
      final String plain = Krc.decode(realKrcBase64);
      expect(plain, isNotEmpty);
      expect(plain, contains('[ti:'));
      expect(plain, contains('[ar:'));
      expect(plain, contains('[offset:0]'));
      // 行时间轴 [开始毫秒,时长] 与逐字三元组 <开始,时长,0> 都在
      expect(RegExp(r'\[\d+,\d+\]').hasMatch(plain), isTrue);
      expect(RegExp(r'<\d+,\d+,\d+>').hasMatch(plain), isTrue);
    });

    test('真实样本转 LRC 后只剩行时间轴', () {
      final String lrc = Krc.toLrc(Krc.decode(realKrcBase64));
      expect(lrc, isNotEmpty);
      expect(lrc, isNot(contains('<')));
      final RegExp timed = RegExp(r'^\[\d{2}:\d{2}\.\d{2}\].+$');
      final RegExp meta = RegExp(r'^\[[a-z]+:.*\]$');
      for (final String raw in lrc.split('\n')) {
        final String line = raw.trim();
        if (line.isEmpty) continue;
        expect(timed.hasMatch(line) || meta.hasMatch(line), isTrue,
            reason: '异常行：$line');
      }
    });

    test('自造样本：明文 → 加密 → 解密回原文', () {
      final String enc = encryptSample(sampleKrc);
      expect(Krc.looksEncoded(enc), isTrue);
      expect(Krc.decode(enc), sampleKrc);
      final String lrc = Krc.toLrc(sampleKrc);
      expect(lrc, contains('[ti:示例歌名]'));
      expect(lrc, contains('[00:01.00]示例歌名'));
      expect(lrc, contains('[00:03.00]第二行'));
      expect(lrc, isNot(contains('<')));
    });
  });

  group('KRC 容错', () {
    test('空串 / 乱码 / 太短都返回空串且不抛异常', () {
      expect(Krc.decode(''), '');
      expect(Krc.decode('   '), '');
      expect(Krc.decode('不是 base64 的一串中文'), '');
      expect(Krc.decode('a3JjMTs='), '');
      expect(Krc.looksEncoded(''), isFalse);
      expect(Krc.looksEncoded('eW91'), isFalse);
      expect(Krc.decodeBase64('!!!'), isNull);
    });

    test('密钥被换成 8 字节版本时解不开（旧版踩过的坑）', () {
      final List<int> z = zlib.encode(utf8.encode(sampleKrc));
      final List<int> wrongKey = <int>[0x40, 0x47, 0x61, 0x38, 0x3B, 0x39, 0x3B, 0x39];
      final List<int> body = <int>[...Krc.magic];
      for (int i = 0; i < z.length; i++) {
        body.add(z[i] ^ wrongKey[i % wrongKey.length]);
      }
      expect(Krc.decode(base64Encode(body)), '');
    });

    test('toLrc 对空输入返回空串', () {
      expect(Krc.toLrc(''), '');
      expect(Krc.toLrc('   \n  '), '');
    });
  });
}
