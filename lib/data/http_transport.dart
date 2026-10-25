import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/result.dart';
import 'transport.dart';

/// 打到游戏进程自己开的本地假服务器上。
///
/// 目标地址来自 `OfflineRuntime`：它在本机 18680 上起 ServerSocket，
/// 客户端自己的请求也是被 `OfflineHttp.rewrite()` 改到这里来的。
///
/// 两条服务端硬要求：
/// - **必须带 `Content-Length`**，否则请求会被直接拒掉；
/// - 只接受 GET / POST / HEAD。
final class HttpTransport implements Transport {
  HttpTransport({
    this.host = '127.0.0.1',
    this.port = 18680,
    this.connectTimeout = const Duration(seconds: 3),
    // 30 秒是跟服务端自己的 socket 读超时对齐的：它要 copy 整份存档、逐个发奖、
    // 再整份 AtomicFile 落盘，之后才回包。10 秒对 4513 条使命或 4219×30 的赛季太紧 ——
    // 一旦客户端先超时，服务端其实**已经落盘了**，用户却看到"没等到回应"。
    this.readTimeout = const Duration(seconds: 30),
  });

  final String host;
  final int port;
  final Duration connectTimeout;
  final Duration readTimeout;

  @override
  Future<Result<HttpReply>> post(String path, String bodyJson) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    final target = 'http://$host:$port$path';
    try {
      // 不要在这里再套一层 .timeout(connectTimeout)：连接被拒在这台机器上要
      // ~2 秒才抛 SocketException，多一层超时会抢先把它改写成 TimeoutException，
      // 于是"游戏没开"会被误报成"游戏没响应"。连接上界由 client.connectionTimeout 管。
      final request = await client.postUrl(Uri.parse(target));
      request.headers.contentType = ContentType.json;

      final bytes = utf8.encode(bodyJson);
      // 先定长度再写内容：服务端按 HTTP/1.x 解析，缺 Content-Length 会拒绝。
      request.contentLength = bytes.length;
      request.add(bytes);

      final response = await request.close().timeout(readTimeout);
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(readTimeout);

      if (response.statusCode != HttpStatus.ok) {
        return Err(
          AppError(
            kind: AppErrorKind.httpStatus,
            userMessage: '游戏那边回了 HTTP ${response.statusCode}',
            detail:
                'HTTP ${response.statusCode} from $path, body=${_preview(body)}',
          ),
        );
      }
      return Ok(HttpReply(response.statusCode, body));
    } on SocketException catch (error) {
      return Err(
        AppError(
          kind: AppErrorKind.refused,
          userMessage: '连不上游戏，请先把游戏打开',
          detail: 'SocketException on $target: ${error.message}',
        ),
      );
    } on TimeoutException catch (error) {
      return Err(
        AppError(
          kind: AppErrorKind.timeout,
          // 这个区分很重要：连不上是"游戏没开"，不回包是"游戏在但引擎没醒/被冻结"。
          userMessage: '连上了游戏但没等到回应，游戏可能没在运行，或已被系统冻结',
          detail: 'TimeoutException on $target: $error',
        ),
      );
    } on HttpException catch (error) {
      return Err(
        AppError(
          kind: AppErrorKind.httpStatus,
          userMessage: '和游戏之间的本地连接出了错',
          detail: 'HttpException on $target: ${error.message}',
        ),
      );
    } on FormatException catch (error) {
      // 响应体不是合法 UTF-8 时 utf8.decoder 会抛这个。它必须在这里变成 Result，
      // 否则会穿到界面上把"领取中"永久卡住。
      return Err(
        AppError(
          kind: AppErrorKind.badJson,
          userMessage: '游戏回了一段看不懂的内容',
          detail: 'FormatException on $target: ${error.message}',
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  String _preview(String body) =>
      body.length > 120 ? '${body.substring(0, 120)}…' : body;
}
