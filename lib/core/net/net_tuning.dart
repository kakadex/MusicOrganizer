/// 网络并发度与超时的可调参数 —— 移植自旧 net/NetTuning.java。
///
/// 超时用一个百分比倍率整体缩放（源有 4~8 家，逐项暴露秒数既难懂又容易改坏）。
library;

/// 网络并发 / 超时可调参数（纯 Dart）。
abstract final class NetTuning {
  /// 同时处理的文件数：默认 3。
  static const int defaultFileConcurrency = 3;
  static const int minFileConcurrency = 1;
  static const int maxFileConcurrency = 5;

  /// 超时倍率（百分比）：默认 100 即原值。
  static const int defaultTimeoutPercent = 100;
  static const int minTimeoutPercent = 50;
  static const int maxTimeoutPercent = 300;

  /// 界面上的档位：0.5× / 1× / 1.5× / 2× / 3×。
  static const List<int> timeoutSteps = <int>[50, 100, 150, 200, 300];

  static int _fileConcurrency = defaultFileConcurrency;
  static int _timeoutPercent = defaultTimeoutPercent;

  /// 应用一组设置；越界自动收缩到合法区间。返回实际生效的并发度。
  static int apply(int concurrency, int percent) {
    _fileConcurrency = _clamp(concurrency, minFileConcurrency, maxFileConcurrency);
    _timeoutPercent = _clamp(percent, minTimeoutPercent, maxTimeoutPercent);
    return _fileConcurrency;
  }

  static int fileConcurrency() => _fileConcurrency;
  static int timeoutPercent() => _timeoutPercent;

  /// 按倍率缩放一个超时值（毫秒）；下限 300ms。
  static int scale(int ms) {
    final int v = (ms * (_timeoutPercent / 100.0)).round();
    return v < 300 ? 300 : v;
  }

  /// 界面上的档位文案，如「1.5×」。
  static String timeoutLabel(int percent) {
    if (percent % 100 == 0) return '${percent ~/ 100}×';
    return '${(percent / 100.0).toStringAsFixed(1)}×';
  }

  /// 一句话说明当前档位（设置页副标题、日志里用）。
  static String describe() {
    final String hint;
    if (_fileConcurrency <= 1) {
      hint = '逐首处理';
    } else if (_fileConcurrency >= 4) {
      hint = '较激进';
    } else {
      hint = '推荐';
    }
    return '$_fileConcurrency 首并发（$hint）· 超时 ${timeoutLabel(_timeoutPercent)}';
  }

  static int _clamp(int v, int min, int max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }
}
