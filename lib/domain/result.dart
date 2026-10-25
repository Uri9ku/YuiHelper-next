/// 一个操作的结果：要么成功带值，要么失败带一个**已经翻译成人话**的错误。
///
/// 仓储层返回 Result 而不是抛异常 —— 调用方必须显式处理失败分支，
/// 不会因为漏了 try/catch 就把网络错误变成一次崩溃。
sealed class Result<T> {
  const Result();
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.error);

  final AppError error;
}

/// 失败的种类。之所以分得这么细，是因为用户能采取的行动完全不同：
/// 连接被拒 = 游戏没开；超时 = 游戏在但没响应。
enum AppErrorKind {
  /// 连接被拒：游戏进程没在跑，或 18680 没人监听。
  refused,

  /// 连上了但不回包：引擎还没 ready，或进程被系统冻结。
  timeout,

  /// HTTP 状态码不是 200。
  httpStatus,

  /// 响应不是合法 JSON。
  badJson,

  /// 服务端回了 `code != 0`，并带了 message。
  serverCode,

  /// 本地输入不合法（换模型：角色 id 为空/超长/含非法字符/两者相同）。
  invalidInput,
}

final class AppError {
  const AppError({
    required this.kind,
    required this.userMessage,
    required this.detail,
  });

  final AppErrorKind kind;

  /// 直接显示给用户的简体中文一句话。
  final String userMessage;

  /// 给日志看的技术细节，**不要**直接展示在界面上。
  final String detail;
}
