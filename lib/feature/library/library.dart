/// 曲库浏览 feature（T12 落位，三件套：page + controller + widgets）。
///
/// - `library_page.dart`：懒加载列表 + 排序 / 筛选 / 多选 + 搜索栏；
/// - `library_controller.dart`：ListView.builder 懒加载编排；
/// - `widgets/`：行卡片（const 化，R3 性能约束）、搜索语法输入。
library;
