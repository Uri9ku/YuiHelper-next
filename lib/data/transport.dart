import '../domain/result.dart';

/// 一条原始的 HTTP 回应。
final class HttpReply {
  const HttpReply(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// 往游戏进程里的本地假服务器发一条请求。
///
/// [path] 是**请求路径**（形如 `/api/user/pull`），host 与 port 由实现补上。
/// 抽成接口是为了让上层能在不联网的情况下被测试。
abstract interface class Transport {
  Future<Result<HttpReply>> post(String path, String bodyJson);
}
