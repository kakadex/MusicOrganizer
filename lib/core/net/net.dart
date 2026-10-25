/// 网络层（T05 落位）：dart:io HttpClient 封装（**不加 http 包**）。
///
/// - `http_client.dart`：keep-alive 连接池 + 分级超时（连接 3.5s /
///   读取 CN 5s / 海外 8s）+ 按主机熔断（连续失败 2 次冷却 45s、
///   429 冷却 90s）；
/// - `net.dart`：Net.map 文件级并发池（默认 3，可调 1-5）+
///   Net.gather 源级并发（Future.wait + 总预算 12s）；
/// - `net_tuning.dart`：并发度 / 超时档位可调；
/// - `ticket_limiter.dart`：MusicBrainz 1s 票约。
library;
