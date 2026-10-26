/// 匹配层：批量匹配编排与中间态。
///
/// - `match_queue.dart`：匹配中间态落库（14 天续跑）；
/// - `batch_memory.dart`：增量记忆（同批已确认的取舍）；
/// - 文件级 / 源级并发编排由 core/net 的 Net.map / Net.gather 提供。
library;
