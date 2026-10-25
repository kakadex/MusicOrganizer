/// 应用更新判定（纯逻辑：清单解析 / Release 解析 / 版本比较 / 说明整理）。
///
/// 不碰网络与文件：文本由调用方取回后交给 [AppUpdate.parseManifest] 或
/// [AppUpdate.parseRelease]，方便用固定样本做回归测试。
library;

import '../json/json.dart';

/// 一条可用的更新信息。
class Release {
  const Release({
    required this.tag,
    required this.version,
    this.apkUrl = '',
    this.apkSize = 0,
    this.sha256 = '',
    this.notes = '',
    this.pageUrl = '',
    this.apkName = '',
    this.prerelease = false,
  });

  /// 原始 tag（如 `v0.2.1`）；version 是去掉 v 前缀、保留 -beta 后缀的版本。
  final String tag;
  final String version;
  final String apkUrl;
  final int apkSize;
  final String sha256;
  final String notes;
  final String pageUrl;
  final String apkName;
  final bool prerelease;
  bool get hasApk => apkUrl.isNotEmpty;
  /// 展示串（数字开头时补 v）。
  String get display => AppUpdate.display(version);

  @override
  String toString() => apkName.isEmpty ? tag : '$tag · $apkName';
}

/// 更新判定工具（纯 Dart）。
abstract final class AppUpdate {
  /// 解析 GitHub Release 响应；不是对象 / 缺 tag_name 时返回 null。
  static Release? parseRelease(Object? json) {
    Object? root = json;
    if (root is String) root = Json.parseOrNull(root);
    if (root is! Map) return null;
    final String tag = _str(root['tag_name']).trim();
    if (tag.isEmpty) return null;
    String apkUrl = '', apkName = '', sha = '';
    int apkSize = 0;
    final Object? assets = root['assets'];
    if (assets is List) {
      for (final Object? a in assets) {
        if (a is! Map) continue;
        final String name = _str(a['name']);
        final String url = _str(a['browser_download_url']);
        if (!name.toLowerCase().endsWith('.apk') || url.isEmpty) continue;
        apkUrl = url;
        apkName = name;
        apkSize = _num(a['size']).toInt();
        sha = _str(a['digest']);
        if (sha.toLowerCase().startsWith('sha256:')) sha = sha.substring(7);
        break;      }
    }
    return Release(
      tag: tag,
      version: stripPrefix(tag),
      apkUrl: apkUrl,
      apkSize: apkSize,
      sha256: sha,
      notes: _str(root['body']),
      pageUrl: _str(root['html_url']),
      apkName: apkName,
      prerelease: _bool(root['prerelease']) || _bool(root['draft']),
    );
  }

  /// 解析 `dist/latest.txt`（每行 `key=value`，也兼容 `key: value`）。
  ///
  /// [manifestUrl] 是清单自身地址，用来把相对 apk 路径拼成绝对直链。
  static Release? parseManifest(String? text, String manifestUrl) {
    if (text == null || text.trim().isEmpty) return null;
    final Map<String, String> kv = <String, String>{};
    for (final String raw in text.split(RegExp(r'\r?\n'))) {
      final String line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      int sep = line.indexOf('=');
      if (sep <= 0) sep = line.indexOf(':');
      if (sep <= 0) continue;
      kv[line.substring(0, sep).trim().toLowerCase()] =
          line.substring(sep + 1).trim();
    }
    String version = kv['version'] ?? '', tag = kv['tag'] ?? '';
    if (version.isEmpty && tag.isEmpty) return null;
    if (tag.isEmpty) tag = 'v$version';
    if (version.isEmpty) version = stripPrefix(tag);
    final String rel = kv['apk'] ?? '', lower = tag.toLowerCase();
    return Release(
      tag: tag,
      version: stripPrefix(version),
      apkUrl: resolve(manifestUrl, rel),
      apkSize: int.tryParse(kv['size'] ?? '') ?? 0,
      sha256: kv['sha256'] ?? '',
      notes: kv['summary'] ?? '',
      pageUrl: kv['page'] ?? '',
      apkName: rel.isEmpty ? '' : rel.substring(rel.lastIndexOf('/') + 1),
      prerelease: lower.contains('beta') ||
          lower.contains('rc') ||
          lower.contains('alpha'),
    );
  }

  /// 相对路径拼绝对地址：清单在 `.../dist/latest.txt`，apk 写 `dist/x.apk`。
  static String resolve(String manifestUrl, String rel) {
    final String r = rel.trim();
    if (r.isEmpty) return '';
    if (r.startsWith('http://') || r.startsWith('https://')) return r;
    if (manifestUrl.isEmpty) return '';
    String base = manifestUrl;
    final int q = base.indexOf('?');
    if (q > 0) base = base.substring(0, q);
    int cut = base.lastIndexOf('/');
    if (cut > 0) base = base.substring(0, cut);
    cut = base.lastIndexOf('/');
    if (cut > 0) base = base.substring(0, cut + 1);
    return base + r;
  }

  /// 去掉前缀 v / V 与空白，保留后缀（`" v0.2.0-beta "` → `"0.2.0-beta"`）。
  static String stripPrefix(String? version) {
    if (version == null) return '';
    String s = version.trim();
    while (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1).trim();
    }
    return s;
  }

  /// 只保留版本主体的数字段（`v0.1.11` → `0.1.11`）。
  static String normalize(String? version) => _parts(version).join('.');

  /// 比较版本：a 更旧返回负数，相同 0，a 更新返回正数。
  ///
  /// 缺段补 0；数字相同时预发布（alpha/beta/rc 等）算更旧。
  static int compare(String? a, String? b) {
    final List<int> x = _parts(a);
    final List<int> y = _parts(b);
    final int n = x.length > y.length ? x.length : y.length;
    for (int i = 0; i < n; i++) {
      final int p = i < x.length ? x[i] : 0;
      final int q = i < y.length ? y[i] : 0;
      if (p != q) return p < q ? -1 : 1;
    }
    final int ra = _preRank(a);
    final int rb = _preRank(b);
    if (ra == rb) return 0;
    return ra < rb ? -1 : 1;
  }

  /// remote 是否比 installed 新；remote 为空一律 false。
  static bool isNewer(String installed, String? remote) =>
      remote != null &&
      remote.trim().isNotEmpty &&
      compare(remote, installed) > 0;

  /// 展示串：数字开头补 v，其余原样返回。
  static String display(String? version) {
    final String s = stripPrefix(version);
    if (s.isEmpty) return '';
    final int c = s.codeUnitAt(0);
    return c >= 0x30 && c <= 0x39 ? 'v$s' : s;
  }

  /// 字节数转「12.3 MB」；0 或负数返回空串。
  static String humanSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    final double kb = bytes / 1024.0;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    return '${(kb / 1024.0).toStringAsFixed(1)} MB';
  }

  /// 把 Markdown 说明压成可读纯文本（最多 [maxLines] 行、约 900 字）。
  static String shortNotes(String? body, int maxLines) {
    if (body == null || body.trim().isEmpty) return '';
    final List<String> out = <String>[];
    int chars = 0;
    for (final String raw in body.replaceAll('\r\n', '\n').split('\n')) {
      final String s = plain(raw);
      if (s.isEmpty) {
        if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
        continue;
      }
      if (out.length >= maxLines) {
        out.add('…');
        break;
      }
      chars += s.length;
      if (chars > 900) {
        out.add(s.length > 60 ? '${s.substring(0, 60)}…' : s);
        out.add('…（完整说明见发布页）');
        break;
      }
      out.add(s);
    }
    return _join(out);
  }

  /// 去掉单行里的 Markdown 标记（保留列表符号，读起来有层次）。
  static String plain(String line) {
    String s = line.trim();
    if (s.startsWith('```')) return '';
    int hash = 0;
    while (hash < s.length && s.codeUnitAt(hash) == 0x23) {
      hash++;
    }
    if (hash > 0 && hash < s.length && s.codeUnitAt(hash) == 0x20) {
      return '【${s.substring(hash + 1).trim()}】';
    }
    while (s.startsWith('>')) {
      s = s.substring(1).trim();
    }
    s = s
        .replaceAll('**', '')
        .replaceAll('__', '')
        .replaceAll('`', '')
        .replaceAll('~~', '');
    s = _stripLinks(s);
    if (RegExp(r'^[-*_]{3,}$').hasMatch(s)) return '';
    return s.trim();
  }

  /// 取版本主体数字段：最多 4 段，读到数字后再遇字母即停。
  static List<int> _parts(String? version) {
    final String s = stripPrefix(version);
    final List<int> out = <int>[];
    int i = 0;
    while (i < s.length && out.length < 4) {
      final int c = s.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) {
        if (out.isNotEmpty && _isLetter(c)) break;
        i++;
        continue;
      }
      int v = 0;
      while (i < s.length) {
        final int d = s.codeUnitAt(i);
        if (d < 0x30 || d > 0x39) break;
        v = v * 10 + (d - 0x30);
        if (v > 0x7FFFFFFF) v = 0x7FFFFFFF;
        i++;
      }
      out.add(v);
    }
    return out;
  }

  static bool _isLetter(int c) =>
      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  /// 预发布后缀：0 = 预发布，1 = 正式版。
  static int _preRank(String? version) {
    if (version == null) return 1;
    final String s = version.toLowerCase();
    for (final String m in <String>['alpha', 'beta', 'rc', 'dev', 'preview', 'snapshot', 'test']) {
      if (s.contains(m)) return 0;
    }
    return 1;
  }

  static String _stripLinks(String s) {
    final StringBuffer sb = StringBuffer();
    int i = 0;
    while (i < s.length) {
      final int close = s.codeUnitAt(i) == 0x5B ? s.indexOf(']', i) : -1;
      if (close > i && close + 1 < s.length && s.codeUnitAt(close + 1) == 0x28) {
        final int end = s.indexOf(')', close + 2);
        if (end > 0) {
          sb.write(s.substring(i + 1, close));
          i = end + 1;
          continue;
        }
      }
      sb.write(s[i]);
      i++;
    }
    return sb.toString();
  }
  static String _join(List<String> lines) {
    final StringBuffer sb = StringBuffer();
    for (final String l in lines) {
      if (sb.isNotEmpty) sb.write('\n');
      sb.write(l);
    }
    return sb.toString().trim();
  }
  static String _str(Object? v) => v == null ? '' : '$v';
  static bool _bool(Object? v) => v is bool && v;
  static num _num(Object? v) => v is num ? v : 0;
}
