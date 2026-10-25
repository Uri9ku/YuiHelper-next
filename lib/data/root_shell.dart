import 'dart:async';
import 'dart:io';

/// 一次 su 命令的结果。
final class ShellResult {
  const ShellResult(this.code, this.out);

  final int code;
  final String out;

  bool get ok => code == 0;
}

/// su 命令执行封装：`su -c <cmd>`。
///
/// 超时比 saoars_app 的 Java 版保守：root 授权弹窗期间命令会挂住，靠超时兜底。
/// （测试不打真 shell：仓储层的 `shell` 参数可注入假实现。）
final class RootShell {
  const RootShell();

  Future<ShellResult> run(
    String cmd, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      // Process.run 没有 timeout 参数：Future.timeout 到点抛 TimeoutException，
      // 进程会被晾着（su 场景可接受——挂住的原因通常是 root 授权弹窗，不能强杀用户面前的弹窗）。
      final result = await Process.run('su', ['-c', cmd]).timeout(timeout);
      final out =
          ((result.stdout as String?) ?? '') +
          ((result.stderr as String?) ?? '');
      return ShellResult(result.exitCode, out.trim());
    } on TimeoutException {
      return const ShellResult(-1, 'EXEC_FAIL: su command timed out');
    } on ProcessException catch (e) {
      // 设备上没有 su（未 root）——caller 用 hasRoot=false 分支给用户文案。
      return ShellResult(-1, 'EXEC_FAIL: ${e.message}');
    }
  }

  Future<bool> hasRoot() async {
    final r = await run('id', timeout: const Duration(seconds: 8));
    return r.out.contains('uid=0');
  }

  Future<String> pidOf(String name) async {
    final r = await run('pidof $name');
    final s = r.out.trim();
    if (s.isNotEmpty) return s.split(RegExp(r'\s+')).first;
    return '';
  }
}
