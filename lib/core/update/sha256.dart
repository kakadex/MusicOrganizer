/// 纯 Dart SHA-256（零依赖）。
///
/// 桌面端自动更新校验安装包用：下载回来的 zip 要和发布清单里的 SHA256 对上，
/// 才对得起「这是官方那一份」。这里不引 package:crypto——算法不长，自实现
/// 保持零第三方依赖，且能被已知向量（FIPS 180-2）单测钉死。
library;

import 'dart:typed_data';

/// 计算 [data] 的 SHA-256，返回 64 位小写十六进制串。
String sha256Hex(Uint8List data) {
  final _Sha256 h = _Sha256();
  h.update(data);
  final List<int> digest = h.digest();
  final StringBuffer sb = StringBuffer();
  for (final int b in digest) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// 一次性算一个 [Uint8List]（数据已在内存里，不分块）。
String sha256HexBytes(List<int> bytes) => sha256Hex(Uint8List.fromList(bytes));

class _Sha256 {
  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  int _h0 = 0x6a09e667, _h1 = 0xbb67ae85, _h2 = 0x3c6ef372, _h3 = 0xa54ff53a;
  int _h4 = 0x510e527f, _h5 = 0x9b05688c, _h6 = 0x1f83d9ab, _h7 = 0x5be0cd19;
  final Uint8List _buf = Uint8List(64);
  int _bufLen = 0;
  int _total = 0;

  void update(Uint8List data) {
    _total += data.length;
    int off = 0;
    while (off < data.length) {
      final int room = 64 - _bufLen;
      final int n = room < data.length - off ? room : data.length - off;
      _buf.setRange(_bufLen, _bufLen + n, data, off);
      _bufLen += n;
      off += n;
      if (_bufLen == 64) {
        _compress(_buf);
        _bufLen = 0;
      }
    }
  }

  List<int> digest() {
    // 补位：0x80 后面填 0，最后 8 字节写总比特数（大端）
    int bitLen = _total * 8;
    final Uint8List tail = Uint8List(72);
    tail[0] = 0x80;
    int padLen = _bufLen < 56 ? 56 - _bufLen : 120 - _bufLen;
    for (int i = 7; i >= 0; i--) {
      tail[padLen + i] = bitLen & 0xFF;
      bitLen = bitLen >> 8;
    }
    // 把补位字节喂进去（含 8 字节长度）
    update(Uint8List.sublistView(tail, 0, padLen + 8));
    return <int>[
      (_h0 >> 24) & 0xFF, (_h0 >> 16) & 0xFF, (_h0 >> 8) & 0xFF, _h0 & 0xFF,
      (_h1 >> 24) & 0xFF, (_h1 >> 16) & 0xFF, (_h1 >> 8) & 0xFF, _h1 & 0xFF,
      (_h2 >> 24) & 0xFF, (_h2 >> 16) & 0xFF, (_h2 >> 8) & 0xFF, _h2 & 0xFF,
      (_h3 >> 24) & 0xFF, (_h3 >> 16) & 0xFF, (_h3 >> 8) & 0xFF, _h3 & 0xFF,
      (_h4 >> 24) & 0xFF, (_h4 >> 16) & 0xFF, (_h4 >> 8) & 0xFF, _h4 & 0xFF,
      (_h5 >> 24) & 0xFF, (_h5 >> 16) & 0xFF, (_h5 >> 8) & 0xFF, _h5 & 0xFF,
      (_h6 >> 24) & 0xFF, (_h6 >> 16) & 0xFF, (_h6 >> 8) & 0xFF, _h6 & 0xFF,
      (_h7 >> 24) & 0xFF, (_h7 >> 16) & 0xFF, (_h7 >> 8) & 0xFF, _h7 & 0xFF,
    ];
  }

  void _compress(Uint8List block) {
    final List<int> w = List<int>.filled(64, 0);
    for (int i = 0; i < 16; i++) {
      w[i] = (block[i * 4] << 24) |
          (block[i * 4 + 1] << 16) |
          (block[i * 4 + 2] << 8) |
          block[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
      final int s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    int a = _h0, b = _h1, c = _h2, d = _h3;
    int e = _h4, f = _h5, g = _h6, h = _h7;
    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ ((~e) & g);
      final int t1 = (h + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    _h0 = (_h0 + a) & 0xFFFFFFFF;
    _h1 = (_h1 + b) & 0xFFFFFFFF;
    _h2 = (_h2 + c) & 0xFFFFFFFF;
    _h3 = (_h3 + d) & 0xFFFFFFFF;
    _h4 = (_h4 + e) & 0xFFFFFFFF;
    _h5 = (_h5 + f) & 0xFFFFFFFF;
    _h6 = (_h6 + g) & 0xFFFFFFFF;
    _h7 = (_h7 + h) & 0xFFFFFFFF;
  }

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;
}
