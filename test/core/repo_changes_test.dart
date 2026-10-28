/// 按域拆分的变更通知（T-12）：设置项变化不该惊动曲库 / 整理页。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/repo_changes.dart';

void main() {
  test('各域互不牵连', () {
    final RepoChanges c = RepoChanges();
    int library = 0;
    int settings = 0;
    int root = 0;
    c.library.addListener(() => library++);
    c.settings.addListener(() => settings++);
    c.root.addListener(() => root++);

    c.emit(RepoDomain.settings);
    expect(settings, 1);
    expect(library, 0, reason: '改设置不该让曲库页重建');
    expect(root, 0);

    c.emit(RepoDomain.library);
    expect(library, 1);
    expect(settings, 1, reason: '扫描进度不该带着设置页重建');

    c.dispose();
  });

  test('of() 合并多个域：任一域变化都会通知', () {
    final RepoChanges c = RepoChanges();
    final Listenable both =
        c.of(<RepoDomain>[RepoDomain.library, RepoDomain.root]);
    int n = 0;
    both.addListener(() => n++);
    c.emit(RepoDomain.library);
    c.emit(RepoDomain.root);
    c.emit(RepoDomain.settings);
    c.emit(RepoDomain.meta);
    expect(n, 2, reason: '只关心曲目与目录两域');
    c.dispose();
  });
}
