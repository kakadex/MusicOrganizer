/// 进度回调（对应 Python progress 回调）—— 纯 Dart。
abstract class Progress {
  void onProgress(int done, int total, String message);
}
