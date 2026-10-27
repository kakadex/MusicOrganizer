import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import '../../core/source/endpoints.dart';

/// 数据源设置：单独停用某个源、改某个接口的地址、一键恢复默认地址。
///
/// 国内音乐站的匿名接口换得勤，某个源挂了就先把它关掉，不用等发版。
/// 地址留空保存即恢复默认。改完立刻生效（下一次请求就用新地址）。
class DataSourcePage extends StatefulWidget {
  const DataSourcePage({super.key});

  @override
  State<DataSourcePage> createState() => _DataSourcePageState();
}

class _DataSourcePageState extends State<DataSourcePage> {
  /// 按 endpointKey 缓存输入控制器。
  ///
  /// 原来每次 build 都 new 一个、且从不 dispose：既泄漏内存，
  /// 又会在用户正输入时被重建顶掉（点上面的开关 → 文字被重置回默认值）。
  final Map<String, TextEditingController> _ctls =
      <String, TextEditingController>{};

  TextEditingController _ctlFor(String key) => _ctls.putIfAbsent(
      key, () => TextEditingController(text: Endpoints.url(key)));

  @override
  void dispose() {
    for (final TextEditingController c in _ctls.values) {
      c.dispose();
    }
    _ctls.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<EndpointSource> all = Endpoints.sources;
    final List<String> groups = <String>[
      for (final String g in <String>['标签', '歌词', '更新'])
        if (all.any((EndpointSource s) => s.group == g)) g,
    ];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('数据源设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 24),
        children: <Widget>[
          Text('取消勾选就不再向该站发请求；地址留空保存＝恢复默认。改完下一次请求即生效。',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
          const SizedBox(height: 12),
          for (final String g in groups) ...<Widget>[
            _groupHeader(context, g),
            for (final EndpointSource s in all.where((EndpointSource x) => x.group == g))
              _sourceRow(context, s),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          MoButton('恢复默认地址', primary: false, onPressed: _resetAll),
        ],
      ),
    );
  }

  Widget _groupHeader(BuildContext context, String group) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(group,
          style: TextStyle(
              fontSize: MoKit.fsCaption,
              color: MoKit.sub(context),
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _sourceRow(BuildContext context, EndpointSource s) {
    final bool on = Endpoints.enabled(s.key);
    final int changed = _changedCount(s);
    return MoTile(
      title: s.label,
      subtitle: '${s.count} 个接口${changed > 0 ? ' · 已改 $changed 个' : ''}',
      icon: on ? Icons.cloud_outlined : Icons.cloud_off_outlined,
      trailing: Switch(
        value: on,
        onChanged: (bool v) {
          Endpoints.config?.setEnabled(s.key, v);
          setState(() {});
        },
      ),
      onTap: () => _editEndpoints(s),
    );
  }

  int _changedCount(EndpointSource s) {
    int n = 0;
    for (int i = 0; i < s.count; i++) {
      if (Endpoints.customized(s.endpointKey(i))) n++;
    }
    return n;
  }

  Future<void> _editEndpoints(EndpointSource s) async {
    await showMoSheet<void>(
      context,
      title: s.label,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 8),
          child: Text('留空保存＝用回默认地址。只接受 http / https。',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        ),
        for (int i = 0; i < s.count; i++) _endpointEditor(s, i),
        const SizedBox(height: 10),
      ],
    );
    if (mounted) setState(() {});
  }

  Widget _endpointEditor(EndpointSource s, int index) {
    final String key = s.endpointKey(index);
    final String def = s.defaultUrl(index);
    final TextEditingController ctl = _ctlFor(key);
    return Padding(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 6, MoKit.pagePad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(s.name(index).isEmpty ? '接口 ${index + 1}' : s.name(index),
                    style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
              ),
              Text(Endpoints.customized(key) ? '已改' : '默认',
                  style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: ctl,
            maxLines: 2,
            minLines: 1,
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.text(context)),
            decoration: InputDecoration(
              hintText: def,
              hintStyle: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(MoKit.radiusRow)),
            ),
            onSubmitted: (String v) => _saveEndpoint(key, v),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _saveEndpoint(key, ctl.text),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }

  void _saveEndpoint(String key, String value) {
    final String v = value.trim();
    if (v.isNotEmpty && !Endpoints.isValidUrl(v)) {
      moSnack(context, '只接受 http / https 地址');
      return;
    }
    Endpoints.config?.setOverride(key, v.isEmpty ? null : v);
    // 留空保存 = 恢复默认：把框里的文字同步成最终生效的地址
    final TextEditingController? ctl = _ctls[key];
    if (ctl != null) {
      final String effective = Endpoints.url(key);
      if (ctl.text != effective) {
        ctl.value = TextEditingValue(
            text: effective,
            selection: TextSelection.collapsed(offset: effective.length));
      }
    }
    setState(() {});
    moSnack(context, v.isEmpty ? '已恢复默认地址' : '已保存（下次请求生效）');
  }

  Future<void> _resetAll() async {
    final bool? go = await showMoSheet<bool>(
      context,
      title: '恢复默认地址',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 8),
          child: Text('把所有改过的接口地址恢复成内置默认（不会改各源的启用开关）。',
              style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        ),
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: MoButton('恢复', primary: false,
              onPressed: () => Navigator.of(context).pop(true)),
        ),
      ],
    );
    if (go != true) return;
    Endpoints.resetAll();
    if (!mounted) return;
    for (final MapEntry<String, TextEditingController> e in _ctls.entries) {
      final String effective = Endpoints.url(e.key);
      if (e.value.text != effective) {
        e.value.value = TextEditingValue(
            text: effective,
            selection: TextSelection.collapsed(offset: effective.length));
      }
    }
    setState(() {});
    moSnack(context, '已恢复默认地址');
  }
}
