import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/ui_kit.dart';

/// 本项目自己的开源许可（仓库根 `LICENSE`，MIT），中英对照显示。
///
/// 与 Flutter 的 `showLicensePage` 不是一回事：那个列的是**第三方依赖**的许可，
/// 这里只放 MusicOrganizer 自身的授权条款。改许可时 `LICENSE` 与这里要一起改。
const List<List<String>> kLicensePairs = <List<String>>[
  <String>['MIT License', 'MIT 许可协议'],
  <String>['Copyright (c) 2026 kakadex', '版权所有 (c) 2026 kakadex'],
  <String>[
    'Permission is hereby granted, free of charge, to any person obtaining a copy '
        'of this software and associated documentation files (the "Software"), to deal '
        'in the Software without restriction, including without limitation the rights '
        'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell '
        'copies of the Software, and to permit persons to whom the Software is '
        'furnished to do so, subject to the following conditions:',
    '特此免费授予任何获得本软件及相关文档文件（"本软件"）副本的人，不受限制地处理本软件的权利，'
        '包括但不限于使用、复制、修改、合并、发布、分发、再许可和/或销售本软件副本的权利，'
        '并允许获得本软件的人这样做，但须符合以下条件：',
  ],
  <String>[
    'The above copyright notice and this permission notice shall be included in all '
        'copies or substantial portions of the Software.',
    '上述版权声明和本许可声明应包含在本软件的所有副本或实质性部分中。',
  ],
  <String>[
    'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR '
        'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, '
        'FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE '
        'AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER '
        'LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, '
        'OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE '
        'SOFTWARE.',
    '本软件按"现状"提供，不提供任何明示或默示的保证，包括但不限于对适销性、'
        '特定用途适用性及不侵权的保证。在任何情况下，作者或版权持有人均不对任何索赔、'
        '损害或其他责任负责，无论是基于合同、侵权还是其他原因，'
        '因本软件或本软件的使用或其他交易而产生或与之相关。',
  ],
];

/// 中英对照页底部的一句法律提示：中文仅供参考，冲突以英文为准。
const String kLicenseZhDisclaimer = '中文译文仅供参考，如有歧义以英文原文为准。';

/// 纯文本版（复制按钮用）：英文段与中文段交替。
String get kProjectLicenseText =>
    kLicensePairs.map((List<String> p) => '${p[0]}\n\n${p[1]}').join('\n\n');

/// 「开源许可」页：MIT 中英对照 + 一键复制。
class ProjectLicensePage extends StatelessWidget {
  const ProjectLicensePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            PageHeader(
              title: '开源许可',
              subtitle: 'MIT License · 本项目采用（中英对照）',
              leading: IconButton(
                tooltip: '返回',
                icon: Icon(Icons.arrow_back,
                    size: 20, color: MoKit.text(context)),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              actions: <Widget>[
                IconButton(
                  tooltip: '复制全文',
                  icon: Icon(Icons.copy_all_outlined,
                      size: 20, color: MoKit.text(context)),
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: kProjectLicenseText));
                    if (context.mounted) moSnack(context, '许可全文已复制');
                  },
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: <Widget>[
                  SectionCard(
                    title: '音乐整理工具 MusicOrganizer',
                    subtitle: '本项目以 MIT 许可开源：可自由使用、修改、再分发，'
                        '保留版权与许可声明即可。',
                    children: <Widget>[
                      for (int i = 0; i < kLicensePairs.length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(height: 14),
                        SelectableText(kLicensePairs[i][0],
                            style: TextStyle(
                              fontSize: MoKit.fsBody,
                              height: 1.5,
                              color: MoKit.text(context),
                            )),
                        const SizedBox(height: 4),
                        SelectableText(kLicensePairs[i][1],
                            style: TextStyle(
                              fontSize: MoKit.fsBody,
                              height: 1.6,
                              color: MoKit.sub(context),
                            )),
                      ],
                      const SizedBox(height: 14),
                      Text(kLicenseZhDisclaimer,
                          style: TextStyle(
                            fontSize: MoKit.fsCaption,
                            color: MoKit.faint(context),
                          )),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
