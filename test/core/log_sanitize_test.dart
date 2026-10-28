import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/log/log.dart';

/// 日志 / 崩溃页脱敏：本机路径、URI、UNC、凭据都不能原样留下。
void main() {
  test('抹掉 Windows / POSIX 路径、content://、file:// 与 UNC', () {
    const String raw = r'C:\Users\alice\Music\a.mp3 /home/alice/b.mp3 '
        r'content://com.android.externalstorage.documents/tree/primary%3AMusic '
        r'file:///C:/Users/alice/c.mp3 \\server\share\d.mp3';
    final String out = Log.sanitize(raw);

    expect(out.contains('alice'), isFalse);
    expect(out.contains('C:/Users'), isFalse);
    expect(out.contains('content://com.android'), isFalse);
    expect(out.contains('file:///C:'), isFalse);
    expect(out.contains('server'), isFalse);
    // 尾部文件名可以留（排查问题时需要知道是哪个文件）
    expect(out.contains('a.mp3'), isTrue);
    expect(out, contains('content://***'));
  });

  test('抹掉 token / password 值', () {
    expect(Log.sanitize('token=abc123'), contains('token=***'));
    expect(Log.sanitize('password: hunter2'), contains('password=***'));
    expect(Log.sanitize('api_key = sk-xxxx'), contains('api_key=***'));
  });

  test('空值与普通文本不受影响', () {
    expect(Log.sanitize(null), '');
    expect(Log.sanitize('已写入 12 首'), '已写入 12 首');
  });
}
