import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/domain/result.dart';

void main() {
  test('Ok 承载值，且是 Result<T>', () {
    const Result<int> r = Ok(42);
    expect(r, isA<Ok<int>>());
    expect((r as Ok<int>).value, 42);
  });

  test('Err 保留 kind、给用户看的文案、以及给日志看的技术细节', () {
    const Result<int> r = Err(
      AppError(
        kind: AppErrorKind.refused,
        userMessage: '连不上游戏，请先把游戏打开',
        detail: 'SocketException: Connection refused (port 18680)',
      ),
    );
    final e = (r as Err<int>).error;
    expect(e.kind, AppErrorKind.refused);
    expect(e.userMessage, contains('游戏'));
    expect(e.detail, contains('18680'));
  });

  test('六种错误类型都在（连接被拒/超时/HTTP 状态/坏 JSON/服务端 code/本地输入）', () {
    expect(AppErrorKind.values, hasLength(6));
    expect(
      AppErrorKind.values,
      containsAll(<AppErrorKind>[
        AppErrorKind.refused,
        AppErrorKind.timeout,
        AppErrorKind.httpStatus,
        AppErrorKind.badJson,
        AppErrorKind.serverCode,
        AppErrorKind.invalidInput,
      ]),
    );
  });
}

