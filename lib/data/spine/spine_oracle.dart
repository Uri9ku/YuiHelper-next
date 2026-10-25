import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../root_shell.dart';

/// 内置资产读取（frida-inject 二进制 / spine_fetch.js）。
typedef AssetLoader = Future<Uint8List> Function(String asset);

/// 取数失败的分类原因（UI 按此给文案，不吞错）。
enum OracleFailure {
  noRoot,
  gameNotRunning,
  injectorMissing,
  injectorFailed,
  timeout,
  badResult,
  ioError,
}

/// 取数异常：带分类原因与原始输出（便于 UI 如实显示）。
final class SpineOracleException implements Exception {
  const SpineOracleException(this.failure, this.message, {this.detail = ''});

  final OracleFailure failure;
  final String message;
  final String detail;

  @override
  String toString() => 'SpineOracleException($failure): $message'
      '${detail.isEmpty ? '' : ' | $detail'}';
}

/// 取回的一条明文。
final class OracleAsset {
  const OracleAsset({
    required this.logicalPath,
    required this.bytes,
    required this.head,
  });

  final String logicalPath;
  final Uint8List bytes;

  /// 前 24 字节 hex（用于判类型：1c=Spine 骨架 / 504b4d=PKM 页 / 文本 atlas）。
  final String head;

  bool get looksLikeSkeleton => head.startsWith('1c');
  bool get looksLikePkm => head.startsWith('504b4d');
  int get size => bytes.length;
}

/// 取数结果：成功的明文 + 失败项（失败不抛，交由调用方决定降级）。
final class OracleFetchResult {
  const OracleFetchResult({
    required this.assets,
    required this.failures,
    required this.duration,
  });

  final Map<String, OracleAsset> assets;

  /// 逻辑路径 → 失败原因
  final Map<String, String> failures;

  final Duration duration;

  bool get isEmpty => assets.isEmpty;
}

/// 运行时取数（方案 ①，见 docs/可行性分析_APP内实时渲染Spine动作.md §十四）。
///
/// 原理：注入内置 `frida-inject` + `assets/spine_fetch.js`，脚本把
/// `/data/user/0/<游戏包名>/files/yui-spine/request.txt` 里的逻辑路径逐条交给引擎
/// `DataCache::read(path)`，把「已解密+解压」的明文写到同目录 `out/<n>.bin`。
///
/// 已实测（2026-10-25，Xiaomi 24129PN74C / Android 16 / offline mod）：
/// - `.skelenc`（A 类：AES+XZ）可按时取到，大小与本地明文逐字节一致（8,339,008 B）；
/// - `.atlas`（A 类）同样可取；
/// - `.pkmenc`（B 类：第二层加密）`DataCache::read` 返回空 —— 页贴图需走
///   mod 的解码缓存 `files/saoub_all/`（见 [SpineTextureCache]），这是已确认的边界。
final class SpineOracle {
  SpineOracle({
    ShellRunner? shell,
    AssetLoader? assets,
    this.gamePackage = defaultGamePackage,
    this.injectorProcessName = 'yui-spine-inject',
  })  : _shell = shell ?? const RootShell().run,
        _assets = assets ?? _bundleLoad;

  static const String defaultGamePackage = 'com.bandainamcoent.saoars';

  /// 注入器与脚本放在 /data/local/tmp（root 可执行）。
  static const String deviceBinDir = '/data/local/tmp/yui-spine';

  /// 请求/结果放在游戏私有目录（SELinux 不允许 app 域写 /data/local/tmp）。
  static String gameIoDir(String pkg) => '/data/user/0/$pkg/files/yui-spine';

  static const String injectorAsset = 'assets/frida-inject';
  static const String scriptAsset = 'assets/spine_fetch.js';

  /// 脚本注入后等游戏加载、再取数的秒数（脚本内部定时 40s）。
  static const Duration injectTimeout = Duration(seconds: 150);

  final ShellRunner _shell;
  final AssetLoader _assets;
  final String gamePackage;
  final String injectorProcessName;

  String get _ioDir => gameIoDir(gamePackage);
  String get _binPath => '$deviceBinDir/spine-inject';
  String get _scriptPath => '$deviceBinDir/spine_fetch.js';

  /// 取一组逻辑路径的明文。
  ///
  /// [onProgress] 可用来更新 UI（"正在注入…/正在取数…"），不做强制。
  Future<OracleFetchResult> fetch(
    List<String> logicalPaths, {
    void Function(String stage)? onProgress,
  }) async {
    final started = DateTime.now();
    if (logicalPaths.isEmpty) {
      return OracleFetchResult(assets: const {}, failures: const {}, duration: Duration.zero);
    }

    onProgress?.call('检查 root');
    final root = await _shell('id', timeout: const Duration(seconds: 8));
    if (!root.out.contains('uid=0')) {
      throw const SpineOracleException(OracleFailure.noRoot, '没有 root，无法注入取数');
    }

    onProgress?.call('检查游戏进程');
    final pidRes = await _shell('pidof $gamePackage', timeout: const Duration(seconds: 8));
    final pid = pidRes.out.trim().split(RegExp(r'\s+')).firstWhere(
          (s) => s.isNotEmpty && int.tryParse(s) != null,
          orElse: () => '',
        );
    if (pid.isEmpty) {
      throw SpineOracleException(
        OracleFailure.gameNotRunning,
        '游戏没在运行：先打开游戏（进到主界面即可），再回来取数',
      );
    }

    onProgress?.call('部署注入器');
    await _deploy();
    await _prepareIo(logicalPaths);

    onProgress?.call('注入并取数（约 40~60 秒）');
    final run = await _shell(
      'cd $deviceBinDir && ./spine-inject -p $pid -s $_scriptPath',
      timeout: injectTimeout,
    );
    // 注入器退出码不可靠（脚本结束方式不同），以 done.txt 为准
    if (run.out.contains('Unable to find process')) {
      throw SpineOracleException(OracleFailure.injectorFailed, '注入器找不到游戏进程（pid=$pid）', detail: run.out);
    }

    onProgress?.call('读取结果');
    return await _collect(logicalPaths, started, run.out);
  }

  /// 清理设备上的临时明文（默认取完即删，避免残留）。
  Future<void> cleanup() async {
    await _shell('rm -rf $_ioDir', timeout: const Duration(seconds: 20));
  }

  Future<void> _deploy() async {
    final bin = await _assets(injectorAsset);
    final script = await _assets(scriptAsset);
    final dir = await _shell('mkdir -p $deviceBinDir && chmod 777 $deviceBinDir',
        timeout: const Duration(seconds: 15));
    if (!dir.ok && !dir.out.contains('Permission denied')) {
      // 继续尝试写入；真正的失败会在后面暴露
    }

    // 尺寸一致就跳过拷贝（注入器 59 MB，不必每次都搬）
    final stat = await _shell('stat -c %s $_binPath 2>/dev/null');
    final existing = int.tryParse(stat.out.trim()) ?? -1;
    if (existing != bin.length) {
      final cacheFile = await _writeCache('spine-inject.bin', bin);
      final cp = await _shell(
        'cp -f $cacheFile $_binPath && chmod 755 $_binPath',
        timeout: const Duration(seconds: 90),
      );
      if (!cp.ok) {
        throw SpineOracleException(OracleFailure.injectorMissing, '注入器部署失败', detail: cp.out);
      }
    }
    final statScript = await _shell('stat -c %s $_scriptPath 2>/dev/null');
    if ((int.tryParse(statScript.out.trim()) ?? -1) != script.length) {
      final cacheScript = await _writeCache('spine_fetch.js', script);
      final cp = await _shell('cp -f $cacheScript $_scriptPath', timeout: const Duration(seconds: 30));
      if (!cp.ok) {
        throw SpineOracleException(OracleFailure.injectorMissing, '取数脚本部署失败', detail: cp.out);
      }
    }
  }

  Future<void> _prepareIo(List<String> paths) async {
    final req = await _writeCache('spine_request.txt', utf8.encode('${paths.join('\n')}\n'));
    final setup = await _shell(
      'rm -rf $_ioDir && mkdir -p $_ioDir/out && chmod -R 777 $_ioDir && '
      'cp -f $req $_ioDir/request.txt && chmod 666 $_ioDir/request.txt && '
      'chown -R \$(stat -c %u /data/user/0/$gamePackage) $_ioDir',
      timeout: const Duration(seconds: 30),
    );
    if (!setup.ok) {
      throw SpineOracleException(OracleFailure.ioError, '准备取数目录失败', detail: setup.out);
    }
  }

  Future<OracleFetchResult> _collect(
    List<String> requested,
    DateTime started,
    String injectorOut,
  ) async {
    final assets = <String, OracleAsset>{};
    final failures = <String, String>{};

    final resultJson = await _readDeviceFile('$_ioDir/result.json');
    if (resultJson == null || resultJson.trim().isEmpty) {
      final done = await _readDeviceFile('$_ioDir/done.txt') ?? '';
      throw SpineOracleException(
        OracleFailure.badResult,
        '取数脚本没有产出结果（done=${done.trim()}）',
        detail: injectorOut,
      );
    }

    final List<dynamic> items;
    try {
      items = jsonDecode(resultJson) as List<dynamic>;
    } catch (e) {
      throw SpineOracleException(OracleFailure.badResult, '结果 JSON 解析失败', detail: '$e');
    }

    for (final item in items) {
      final m = item as Map<String, dynamic>;
      final path = (m['path'] as String?) ?? '';
      final err = m['err'] as String?;
      if (path.isEmpty) continue;
      if (err != null && err.isNotEmpty) {
        failures[path] = err;
        continue;
      }
      final file = (m['file'] as String?) ?? '';
      if (file.isEmpty) {
        failures[path] = 'no file';
        continue;
      }
      final bytes = await _readDeviceBinary('$_ioDir/$file');
      if (bytes == null) {
        failures[path] = '读取明文失败';
        continue;
      }
      assets[path] = OracleAsset(
        logicalPath: path,
        bytes: bytes,
        head: _hexHead(bytes),
      );
    }

    // 请求但脚本没返回的，记为失败（不静默）
    for (final path in requested) {
      if (!assets.containsKey(path) && !failures.containsKey(path)) {
        failures[path] = '脚本未返回';
      }
    }

    return OracleFetchResult(
      assets: assets,
      failures: failures,
      duration: DateTime.now().difference(started),
    );
  }

  Future<String?> _readDeviceFile(String path) async {
    final r = await _shell('cat $path 2>/dev/null', timeout: const Duration(seconds: 30));
    final out = r.out.trim();
    if (!r.ok || out.isEmpty) return null;
    return out;
  }

  Future<Uint8List?> _readDeviceBinary(String path) async {
    // base64 走 shell，避免二进制经字符串通道被破坏
    final r = await _shell('base64 $path 2>/dev/null', timeout: const Duration(seconds: 60));
    if (!r.ok || r.out.trim().isEmpty) return null;
    try {
      return base64Decode(r.out.replaceAll(RegExp(r'\s'), ''));
    } catch (_) {
      return null;
    }
  }

  Future<String> _writeCache(String name, List<int> bytes) async {
    final dir = Directory('${Directory.systemTemp.path}/yui-spine');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}/$name');
    f.writeAsBytesSync(bytes);
    return f.path;
  }

  static String _hexHead(Uint8List bytes) {
    final n = bytes.length < 24 ? bytes.length : 24;
    final sb = StringBuffer();
    for (var i = 0; i < n; i++) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Future<Uint8List> _bundleLoad(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List();
  }
}
