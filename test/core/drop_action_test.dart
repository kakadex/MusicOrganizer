import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/platform/drop_channel.dart';

/// 拖放路径解析（纯逻辑）：不碰真实文件系统，目录判定注入。
void main() {
  bool Function(String) dirs(Set<String> existing) =>
      (String p) => existing.contains(p.replaceAll('\\', '/'));

  test('拖进来一个文件夹 → 直接当曲库根', () {
    final DropResult? r = DropAction.resolve(
      <String>[r'C:\Music\Rock'],
      isDirectory: dirs(<String>{'C:/Music/Rock'}),
    );
    expect(r, isNotNull);
    expect(r!.rootPath, r'C:\Music\Rock');
    expect(r.fromDirectory, isTrue);
    expect(r.fileCount, 0);
    expect(r.describe(), contains('已切换到'));
  });

  test('拖进来若干文件 → 取它们所在目录', () {
    final DropResult? r = DropAction.resolve(
      <String>[r'C:\Music\a.mp3', r'C:\Music\b.flac'],
      isDirectory: dirs(<String>{}),
    );
    expect(r, isNotNull);
    expect(r!.rootPath, r'C:\Music');
    expect(r.fromDirectory, isFalse);
    expect(r.fileCount, 2);
    expect(r.describe(), contains('2 个文件'));
  });

  test('正斜杠路径同样处理', () {
    final DropResult? r = DropAction.resolve(
      <String>['/home/u/music/a.mp3'],
      isDirectory: dirs(<String>{}),
    );
    expect(r!.rootPath, '/home/u/music');
  });

  test('空列表 / 全是空串 → 返回 null', () {
    expect(DropAction.resolve(<String>[], isDirectory: dirs(<String>{})), isNull);
    expect(DropAction.resolve(<String>['  ', ''], isDirectory: dirs(<String>{})), isNull);
    expect(DropAction.resolve(null, isDirectory: dirs(<String>{})), isNull);
  });

  test('多目录只认第一个（避免「到底看哪个」的歧义）', () {
    final DropResult? r = DropAction.resolve(
      <String>[r'C:\A', r'C:\B'],
      isDirectory: dirs(<String>{'C:/A', 'C:/B'}),
    );
    expect(r!.rootPath, r'C:\A');
  });

  test('文件与目录混拖 → 目录优先', () {
    final DropResult? r = DropAction.resolve(
      <String>[r'C:\Music\a.mp3', r'C:\Other'],
      isDirectory: dirs(<String>{'C:/Other'}),
    );
    expect(r!.fromDirectory, isTrue);
    expect(r.rootPath, r'C:\Other');
  });

  test('路径没有父级（如 C: 根下裸文件）→ 返回 null，不猜', () {
    expect(
      DropAction.resolve(<String>['a.mp3'], isDirectory: dirs(<String>{})),
      isNull,
    );
  });
}
