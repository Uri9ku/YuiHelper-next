import 'dart:convert';

import '../domain/result.dart';
import 'transport.dart';

/// 本地假服务器的 API 客户端。
///
/// 只负责「发请求 + 把响应解成 JSON 对象」，**不解释业务**：
/// `code != 0` 的判定、可领项的过滤、多轮收敛都留给上层
/// （否则这里会长成一个什么都懂也什么都测不了的类）。
final class LocalApiClient {
  LocalApiClient(this._transport);

  final Transport _transport;

  /// 调一条 action。返回响应解出来的 JSON 对象。
  Future<Result<Map<String, Object?>>> call(
    String action,
    Map<String, Object?> body,
  ) async {
    final path = '/api/$action';
    final result = await _transport.post(path, jsonEncode(body));

    switch (result) {
      case Err<HttpReply>(:final error):
        return Err(error);
      case Ok<HttpReply>(:final value):
        return _decodeObject(value.body, path);
    }
  }

  /// 「引擎活着吗」的探针。
  ///
  /// 用只读的 `mission/refresh`：它不会改存档，而且如果引擎还没 ready，
  /// 服务端的 `serve()` 会卡在 `awaitReady()` 上不回包 —— 那正好就是超时，
  /// 也正好是我们要区分给用户看的那种失败。
  ///
  /// 拿到任何合法 JSON 对象就算活着，**不**要求 `code == 0`。
  Future<Result<bool>> ping() async {
    final result = await call('mission/refresh', const {});

    switch (result) {
      case Err<Map<String, Object?>>(:final error):
        return Err(error);
      case Ok<Map<String, Object?>>():
        return const Ok(true);
    }
  }

  /// 全量拉一张表。
  ///
  /// `hash` 里给一个哨兵值，服务端就会发现版本不匹配、把整张表回给我们
  /// （`mission/refresh` 那种增量接口是拿不到全量行的，见 design §4.1）。
  Future<Result<Map<String, Object?>>> pull(String alias) => call('user/pull', {
    'hash': {alias: '0'},
  });

  Result<Map<String, Object?>> _decodeObject(String body, String path) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      return Err(
        AppError(
          kind: AppErrorKind.badJson,
          userMessage: '游戏回了一段看不懂的内容',
          detail:
              'FormatException on $path: ${error.message}; body=${_preview(body)}',
        ),
      );
    }

    if (decoded is! Map) {
      return Err(
        AppError(
          kind: AppErrorKind.badJson,
          userMessage: '游戏回了一段看不懂的内容',
          detail:
              'Expected a JSON object on $path but got ${decoded.runtimeType}; '
              'body=${_preview(body)}',
        ),
      );
    }

    return Ok(decoded.cast<String, Object?>());
  }

  String _preview(String body) =>
      body.length > 120 ? '${body.substring(0, 120)}…' : body;
}
