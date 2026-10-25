import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/http_transport.dart';
import 'package:yui_helper_next/data/local_api_client.dart';
import 'package:yui_helper_next/data/transport.dart';
import 'package:yui_helper_next/domain/result.dart';

/// 记录调用、按剧本回应的传输层替身。
final class FakeTransport implements Transport {
  FakeTransport(this._script);

  final Future<Result<HttpReply>> Function(String path, String bodyJson) _script;

  final List<String> paths = [];
  final List<String> bodies = [];

  String get lastPath => paths.last;
  String get lastBody => bodies.last;

  @override
  Future<Result<HttpReply>> post(String path, String bodyJson) {
    paths.add(path);
    bodies.add(bodyJson);
    return _script(path, bodyJson);
  }
}

const AppError _refused = AppError(
  kind: AppErrorKind.refused,
  userMessage: '连不上游戏，请先把它打开',
  detail: 'SocketException: Connection refused',
);

/// 起一个"只接不回"的服务端，用来触发读取超时。
Future<HttpServer> _silentServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((_) {
    // 故意不回包：模拟引擎没 ready 或进程被冻结。
  });
  return server;
}

/// 起一个固定状态码的服务端，并回一个无法解析成 JSON 的 body。
Future<HttpServer> _htmlServer(int statusCode) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = statusCode;
    request.response.write('<html>503 Service Unavailable</html>');
    await request.response.close();
  });
  return server;
}

void main() {
  group('HttpTransport 真实收发', () {
    test('发出的请求带 Content-Length，且 body 与传入完全一致', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      const payload = '{"hash":{"mission":"0"}}';
      int? seenLength;
      String? seenBody;
      final handled = Completer<void>();

      server.listen((request) async {
        seenLength = request.contentLength;
        seenBody = await utf8.decoder.bind(request).join();
        request.response.statusCode = 200;
        request.response.write('{"code":0}');
        await request.response.close();
        if (!handled.isCompleted) handled.complete();
      });

      final result = await HttpTransport(port: server.port)
          .post('/api/user/pull', payload);
      await handled.future;

      // 服务端只接受带 Content-Length 的 POST，缺了它会直接拒掉。
      expect(seenLength, utf8.encode(payload).length);
      expect(seenBody, payload);

      expect(result, isA<Ok<HttpReply>>());
      final reply = (result as Ok<HttpReply>).value;
      expect(reply.statusCode, 200);
      expect(reply.body, '{"code":0}');
    });

    test('连到没人监听的端口 → refused，且文案让用户先去开游戏', () async {
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      final result = await HttpTransport(
        port: port,
        // 这台机器上「连接被拒」要约 2 秒才返回，所以给足余量，
        // 否则会变成在测 connectionTimeout 而不是 refused。
        connectTimeout: const Duration(seconds: 10),
      ).post('/api/ping', '{}');

      expect(result, isA<Err<HttpReply>>());
      final error = (result as Err<HttpReply>).error;
      expect(error.kind, AppErrorKind.refused);
      expect(error.userMessage, contains('游戏'));
    });

    test('连上了但不回包 → timeout，且文案指出是游戏没响应', () async {
      final server = await _silentServer();
      addTearDown(server.close);

      final result = await HttpTransport(
        port: server.port,
        readTimeout: const Duration(milliseconds: 300),
      ).post('/api/ping', '{}');

      expect(result, isA<Err<HttpReply>>());
      final error = (result as Err<HttpReply>).error;
      expect(error.kind, AppErrorKind.timeout);
      expect(error.userMessage, contains('游戏'));
    });

    test('非 200 → httpStatus，不把错误页当数据', () async {
      final server = await _htmlServer(503);
      addTearDown(server.close);

      final result = await HttpTransport(port: server.port).post('/api/ping', '{}');

      expect(result, isA<Err<HttpReply>>());
      final error = (result as Err<HttpReply>).error;
      expect(error.kind, AppErrorKind.httpStatus);
      expect(error.detail, contains('503'));
    });

    test('响应体不是合法 UTF-8 → badJson，而不是把 FormatException 抛出去', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        request.response.statusCode = 200;
        request.response.add(const [0xC3, 0x28, 0xFF]); // 非法 UTF-8 序列
        await request.response.close();
      });

      final result = await HttpTransport(port: server.port).post('/api/ping', '{}');

      expect(result, isA<Err<HttpReply>>());
      expect((result as Err<HttpReply>).error.kind, AppErrorKind.badJson);
    });

    test('默认读超时与服务端自己的 30 秒 socket 读超时对齐', () {
      // 服务端要 copy 整份存档、逐个发奖、再整份落盘，之后才回包；
      // 10 秒对 4513 条使命或 4219×30 的赛季太紧，会报"超时"但其实已经落盘了。
      expect(HttpTransport().readTimeout, const Duration(seconds: 30));
    });
  });

  group('LocalApiClient', () {
    test('call 走 /api/<action>，body 原样交给传输层', () async {
      final fake = FakeTransport((_, _) async => const Ok(HttpReply(200, '{"code":0}')));
      await LocalApiClient(fake).call('mission/receive', {'missionIds': [1]});

      expect(fake.paths.single, '/api/mission/receive');
      expect(jsonDecode(fake.bodies.single), {'missionIds': [1]});
    });

    test('HTTP 200 但 body 不是 JSON → badJson，不当成成功', () async {
      final fake = FakeTransport(
        (_, _) async => const Ok(HttpReply(200, '<html>503</html>')),
      );
      final result = await LocalApiClient(fake).call('ping', {});

      expect(result, isA<Err<Map<String, Object?>>>());
      expect(
        (result as Err<Map<String, Object?>>).error.kind,
        AppErrorKind.badJson,
      );
    });

    test('body 是合法 JSON 但不是对象 → badJson', () async {
      final fake = FakeTransport((_, _) async => const Ok(HttpReply(200, '[1,2]')));
      final result = await LocalApiClient(fake).call('ping', {});

      expect(
        (result as Err<Map<String, Object?>>).error.kind,
        AppErrorKind.badJson,
      );
    });

    test('传输层的失败原样透传，kind 与文案都不被改写', () async {
      final fake = FakeTransport((_, _) async => const Err<HttpReply>(_refused));
      final result = await LocalApiClient(fake).call('ping', {});

      final error = (result as Err<Map<String, Object?>>).error;
      expect(error.kind, AppErrorKind.refused);
      expect(error.userMessage, _refused.userMessage);
    });

    test('pull(alias) 走 user/pull，body 是 {"hash":{"<alias>":"0"}}', () async {
      final fake = FakeTransport((_, _) async => const Ok(HttpReply(200, '{"code":0}')));
      await LocalApiClient(fake).pull('mission');

      expect(fake.paths.single, '/api/user/pull');
      expect(fake.bodies.single, '{"hash":{"mission":"0"}}');
    });

    test('ping 成功时返回 Ok(true)', () async {
      final fake = FakeTransport((_, _) async => const Ok(HttpReply(200, '{"code":0}')));
      final result = await LocalApiClient(fake).ping();

      expect(result, isA<Ok<bool>>());
      expect((result as Ok<bool>).value, isTrue);
    });

    test('ping 失败时返回 Err，而不是 Ok(false)', () async {
      final fake = FakeTransport((_, _) async => const Err<HttpReply>(_refused));
      final result = await LocalApiClient(fake).ping();

      expect(result, isA<Err<bool>>());
    });
  });
}

