import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../domain/model_enum.dart';
import '../domain/model_swap_rule.dart';
import '../domain/name_table.dart';
import '../domain/result.dart';
import 'root_shell.dart';

/// 设备侧路径与常量（设计文档 §4.2-2：全部带 `saoub-model-` 前缀，
/// 与「SAOUB修改器」的 `saoub-*` 完全隔离，互不 pkill、互不覆盖）。
final class ModelSwapPaths {
  static const gamePkg = 'com.bandainamcoent.saoars';
  static const tmp = '/data/local/tmp';
  static const binPath = '$tmp/saoub-model-inject';
  static const hookPath = '$tmp/saoub-model.js';
  static const rulesPath = '$tmp/saoub-model-rules.json';
  static const enumPath = '$tmp/saoub-model-enum.json';
  static const logPath = '$tmp/saoub-model-inject.log';
  static const namesPath = '$tmp/saoub-model-names.tsv';
  static const pairsPath = '$tmp/saoub-model-pairs.json';
  static const bonesPath = '$tmp/saoub-model-bones.json';
  static const skeletonsPath = '$tmp/saoub-model-skeletons.json';
  static const injectorProc = 'saoub-model-inject';
}

/// 换模型功能需要的三个 APK 内置资产。
abstract class SwapAssets {
  Future<List<int>> load(String asset);
}

class _BundleAssets implements SwapAssets {
  @override
  Future<List<int>> load(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List();
  }
}

/// 环境事实：root / 游戏进程 / 注入器，各自独立报告。
final class SwapStatus {
  const SwapStatus({
    required this.hasRoot,
    required this.gameRunning,
    required this.injectorRunning,
    this.gamePid,
    this.injectorPid,
  });

  final bool hasRoot;
  final bool gameRunning;
  final bool injectorRunning;
  final String? gamePid;
  final String? injectorPid;
}

/// 换模型功能的设备操作接口。
///
/// 页面依赖这个接口而不是具体仓储，测试才能塞假实现（`final class` 不能被 implements）。
abstract interface class ModelSwapApi {
  Future<SwapStatus> status();
  Future<Result<List<String>>> deploy();
  Future<Result<String>> start();
  Future<Result<void>> stop();
  Future<Result<void>> applyRule(ModelSwapRule? rule);
  Future<Result<ModelEnumSnapshot>> readEnum();
  Future<Result<Map<String, String>>> readNames();

  /// 图集变体 -> 骨架集（chara_N）。用来把「替换成」的候选限制在同一骨架集内：
  /// 跨骨架集的图集换过去会缺骨架/比例错，同集才能正确渲染。
  Future<Result<Map<String, String>>> readVariantBones();
  Future<Result<String>> logSnapshot();
}

/// 换模型功能的设备操作仓储：部署、注入启停、规则读写、枚举与日志。
///
/// 所有方法返回 [Result] 不抛异常；`detail` 里放技术细节，界面上只显示 `userMessage`。
final class ModelSwapRepository implements ModelSwapApi {
  ModelSwapRepository({
    Future<ShellResult> Function(String cmd, {Duration timeout})? shell,
    SwapAssets? assets,
  }) : _shell = shell ?? RootShell().run,
       _assets = assets ?? _BundleAssets();

  final Future<ShellResult> Function(String cmd, {Duration timeout}) _shell;
  final SwapAssets _assets;

  // ------------------------------------------------------------------
  // 状态
  // ------------------------------------------------------------------

  @override
  Future<SwapStatus> status() async {
    final root = await _shell('id');
    final hasRoot = root.out.contains('uid=0');

    var gamePid = '';
    var injectorPid = '';
    if (hasRoot) {
      gamePid = await _pidOf(ModelSwapPaths.gamePkg);
      injectorPid = await _pidOf(ModelSwapPaths.injectorProc);
    }
    return SwapStatus(
      hasRoot: hasRoot,
      gameRunning: gamePid.isNotEmpty,
      injectorRunning: injectorPid.isNotEmpty,
      gamePid: gamePid.isEmpty ? null : gamePid,
      injectorPid: injectorPid.isEmpty ? null : injectorPid,
    );
  }

  Future<String> _pidOf(String name) async {
    final r = await _shell('pidof $name');
    final s = r.out.trim();
    return s.isEmpty ? '' : s.split(RegExp(r'\s+')).first;
  }

  // ------------------------------------------------------------------
  // 部署
  // ------------------------------------------------------------------

  /// 释放资产到 app 缓存目录，再用 su 拷到 /data/local/tmp 并给执行位。
  /// 返回步骤日志（界面上逐行展示）。
  @override
  Future<Result<List<String>>> deploy() async {
    final steps = <String>[];
    try {
      final cache = Directory.systemTemp.path;

      final bin = await _assets.load('assets/frida-inject');
      final binFile = File('$cache/saoub-model-inject.bin');
      await binFile.writeAsBytes(bin, flush: true);
      steps.add('注入器就绪：${bin.length ~/ 1024 ~/ 1024} MB');

      final js = await _assets.load('assets/saoars_model.js');
      final jsFile = File('$cache/saoub-model.js');
      // 原样写盘：hook 脚本是 JS 文本，但**不能**先 decode 再 encode ——
      // 资产里混进一个非 UTF-8 字节就会抛 FormatException（不在这层 catch 里，直接崩页面）。
      await jsFile.writeAsBytes(js, flush: true);
      steps.add('hook 脚本就绪：${js.length} 字节');

      // 二进制大，已存在则不重复拷贝（与 saoars_app 的 Injector.deploy 同策略）
      final r1 = await _shell(
        "cmp -s ${ModelSwapPaths.binPath} '${binFile.path}' && echo SAME_BIN || "
        "(cp -f '${binFile.path}' ${ModelSwapPaths.binPath} && chmod 755 ${ModelSwapPaths.binPath} && echo DEPLOYED_BIN)",
        timeout: const Duration(seconds: 30),
      );
      steps.add(
        r1.out.contains('SAME_BIN')
            ? '注入器已部署过，跳过拷贝'
            : (r1.out.contains('DEPLOYED_BIN')
                  ? '部署注入器：成功'
                  : '部署注入器：${r1.out}'),
      );

      final r2 = await _shell(
        "cp -f '${jsFile.path}' ${ModelSwapPaths.hookPath} && chmod 644 ${ModelSwapPaths.hookPath} && echo OK_HOOK",
      );
      steps.add(r2.out.contains('OK_HOOK') ? '部署脚本：成功' : '部署脚本：${r2.out}');

      // hook 跑在游戏 uid 下，无法在 root 目录里建文件——必须先建好再 chmod 666
      final r3 = await _shell(
        'touch ${ModelSwapPaths.rulesPath} ${ModelSwapPaths.enumPath} '
        '${ModelSwapPaths.skeletonsPath} '
        '&& chmod 666 ${ModelSwapPaths.rulesPath} ${ModelSwapPaths.enumPath} '
        '${ModelSwapPaths.skeletonsPath} && echo OK_PREP',
      );
      steps.add(
        r3.out.contains('OK_PREP') ? '预建规则/枚举文件：成功 (666)' : '预建文件：${r3.out}',
      );

      // 名称表：内置为底，设备覆盖文件由用户自行放置（readNames 时读取）
      final names = await _assets.load('assets/names.tsv');
      final namesFile = File('$cache/saoub-model-names.tsv');
      await namesFile.writeAsBytes(names, flush: true);
      final r4 = await _shell(
        "cp -f '${namesFile.path}' ${ModelSwapPaths.namesPath} && chmod 644 ${ModelSwapPaths.namesPath} && echo OK_NAMES",
      );
      steps.add(r4.out.contains('OK_NAMES') ? '名称表部署：成功' : '名称表部署：${r4.out}');

      // 静态配对表（身体 id -> 脸 id）：没有它，目标角色没被加载过就解析不出脸 id，
      // 换模型会因为"脸是空的"而看起来失败（详见设计文档 §2.11）。
      final pairs = await _assets.load('assets/model_pairs.json');
      final pairsFile = File('$cache/saoub-model-pairs.json');
      await pairsFile.writeAsBytes(pairs, flush: true);
      final r5 = await _shell(
        "cp -f '${pairsFile.path}' ${ModelSwapPaths.pairsPath} && chmod 644 ${ModelSwapPaths.pairsPath} && echo OK_PAIRS",
      );
      steps.add(r5.out.contains('OK_PAIRS') ? '配对表部署：成功' : '配对表部署：${r5.out}');

      // 骨架名种子：跨骨架集互换需要目标骨架集的骨架文件名。清单里没有这份数据，
      // 只能运行时学；这里先放一份种子让跨集**立刻可用**，hook 学到真名后会覆盖。
      // 只在设备文件为空时写入，避免把已经学到的真实名字冲掉。
      final seed = await _assets.load('assets/model_skeletons_seed.json');
      final seedFile = File('$cache/saoub-model-skeletons-seed.json');
      await seedFile.writeAsBytes(seed, flush: true);
      final r6 = await _shell(
        "[ -s ${ModelSwapPaths.skeletonsPath} ] || cp -f '${seedFile.path}' ${ModelSwapPaths.skeletonsPath}; "
        'chmod 666 ${ModelSwapPaths.skeletonsPath} && echo OK_SEED',
      );
      steps.add(r6.out.contains('OK_SEED') ? '骨架种子：成功' : '骨架种子：${r6.out}');

      // 骨架集表（图集变体 -> chara_N）：骨架集不同的角色之间不能只换图集，
      // 否则模型建不起来（黑屏/没头）。有了这张表脚本能在改写前拒绝跨集替换。
      final bones = await _assets.load('assets/model_bones.json');
      final bonesFile = File('$cache/saoub-model-bones.json');
      await bonesFile.writeAsBytes(bones, flush: true);
      final r7 = await _shell(
        "cp -f '${bonesFile.path}' ${ModelSwapPaths.bonesPath} && chmod 644 ${ModelSwapPaths.bonesPath} && echo OK_BONES",
      );
      steps.add(r7.out.contains('OK_BONES') ? '骨架集表部署：成功' : '骨架集表部署：${r7.out}');
      return Ok(steps);
    } on FileSystemException catch (e) {
      return Err(
        AppError(
          kind: AppErrorKind.invalidInput,
          userMessage: '释放内置文件失败，请重试一次。',
          detail: e.toString(),
        ),
      );
    }
  }

  // ------------------------------------------------------------------
  // 注入启停
  // ------------------------------------------------------------------

  @override
  Future<Result<String>> start() async {
    // 先判 root：否则没 root 时 pidof 永远为空，会误报「先打开游戏」，
    // 用户按提示去开游戏再点还是失败，猜不到真正原因。
    final root = await _shell('id');
    if (!root.out.contains('uid=0')) {
      return const Err(
        AppError(
          kind: AppErrorKind.refused,
          userMessage: '没有拿到 root，换模型必须 root 才能注入。请先在 KernelSU 里授权本应用。',
          detail: 'su id did not return uid=0',
        ),
      );
    }

    final gamePid = await _pidOf(ModelSwapPaths.gamePkg);
    if (gamePid.isEmpty) {
      return const Err(
        AppError(
          kind: AppErrorKind.invalidInput,
          userMessage: '先打开游戏再回来启动注入。',
          detail: 'game process not found',
        ),
      );
    }

    // 停旧的（只杀自己的注入器）
    await _shell('pkill -f ${ModelSwapPaths.injectorProc}');
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // 按 pid 注入：真机上游戏在后台时按名字找不到进程（saoars_app 实测）
    final cmd =
        'cd ${ModelSwapPaths.tmp} && nohup ${ModelSwapPaths.binPath}'
        ' -p $gamePid -s ${ModelSwapPaths.hookPath}'
        ' >> ${ModelSwapPaths.logPath} 2>&1 &';
    await _shell(cmd, timeout: const Duration(seconds: 15));

    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final pid = await _pidOf(ModelSwapPaths.injectorProc);
    if (pid.isNotEmpty) {
      return Ok('注入器已启动（PID $pid）');
    }
    final logTail = await _rawTail();
    return Err(
      AppError(
        kind: AppErrorKind.timeout,
        userMessage: '注入器没起来。最常见的原因是 root 授权没给。',
        detail: 'injector not running; log tail: $logTail',
      ),
    );
  }

  @override
  Future<Result<void>> stop() async {
    // 不依赖 pkill 的退出码：`su -c 'pkill -f saoub-model-inject'` 里，
    // su 启动的 sh 自身命令行就含这个模式，pkill -f 可能把那个 shell 也打死，
    // 于是 su 返回 143 而注入器其实已经停了 → 用 pidof 复核真实结果。
    await _shell('pkill -f ${ModelSwapPaths.injectorProc}');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    var pid = await _pidOf(ModelSwapPaths.injectorProc);
    if (pid.isEmpty) return const Ok(null);

    await _shell('pkill -9 -f ${ModelSwapPaths.injectorProc}');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    pid = await _pidOf(ModelSwapPaths.injectorProc);
    if (pid.isEmpty) return const Ok(null);

    return Err(
      AppError(
        kind: AppErrorKind.timeout,
        userMessage: '停止注入失败，注入器还在跑（可能 root 授权被拒）。请重试或重启手机。',
        detail: 'injector still running after pkill/pkill -9, pid=$pid',
      ),
    );
  }

  // ------------------------------------------------------------------
  // 规则
  // ------------------------------------------------------------------

  @override
  Future<Result<void>> applyRule(ModelSwapRule? rule) async {
    final json = buildModelRulesJson(rule);
    try {
      final tmp = File('${Directory.systemTemp.path}/saoub-model-rules.json');
      await tmp.writeAsString(json, flush: true);
      final r = await _shell(
        "cp -f '${tmp.path}' ${ModelSwapPaths.rulesPath} && chmod 666 ${ModelSwapPaths.rulesPath} && echo OK_RULES",
      );
      if (r.out.contains('OK_RULES')) {
        return const Ok(null);
      }
      return Err(
        AppError(
          kind: AppErrorKind.timeout,
          userMessage: '规则写不进去，请确认 root 授权后重试。',
          detail: r.out,
        ),
      );
    } on FileSystemException catch (e) {
      return Err(
        AppError(
          kind: AppErrorKind.invalidInput,
          userMessage: '本地暂存规则文件失败，请重试。',
          detail: e.toString(),
        ),
      );
    }
  }

  // ------------------------------------------------------------------
  // 枚举 / 名称表 / 日志
  // ------------------------------------------------------------------

  @override
  Future<Result<ModelEnumSnapshot>> readEnum() async {
    final r = await _shell(
      'cat ${ModelSwapPaths.enumPath} 2>/dev/null',
      timeout: const Duration(seconds: 15),
    );
    if (!r.ok) return const Ok(ModelEnumSnapshot(characters: []));
    return Ok(parseModelEnum(r.out));
  }

  @override
  Future<Result<Map<String, String>>> readNames() async {
    final bundled = await _assets.load('assets/names.tsv');
    var table = parseNameTable(utf8.decode(bundled));

    final r = await _shell('cat ${ModelSwapPaths.namesPath} 2>/dev/null');
    final overlay = r.out.trim();
    if (overlay.isNotEmpty) {
      table = {...table, ...parseNameTable(overlay)};
    }
    return Ok(table);
  }

  @override
  Future<Result<Map<String, String>>> readVariantBones() async {
    try {
      final raw = await _assets.load('assets/model_bones.json');
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map) return const Ok(<String, String>{});
      final variants = decoded['variants'];
      if (variants is! Map) return const Ok(<String, String>{});
      final out = <String, String>{};
      variants.forEach((k, v) {
        if (k is String && v is String && v.isNotEmpty) out[k] = v;
      });
      return Ok(out);
    } catch (e) {
      return const Ok(<String, String>{});
    }
  }

  /// 一次 su 调用带回：日志尾部 + MODEL 计数 + MISMATCH 计数 + 字节数。
  /// `@@@COUNTS` 分隔，presentation 负责切分展示。
  @override
  Future<Result<String>> logSnapshot() async {
    final log = ModelSwapPaths.logPath;
    final skels = ModelSwapPaths.skeletonsPath;
    final r = await _shell(
      // 先给一行「已学骨架」——跨骨架集互换需要目标骨架集的骨架文件名，
      // 用户据此判断是否还需要让目标角色先出场一次。
      'echo -n "骨架已学："; '
      "grep -o '\"chara_[0-9a-z]*\":\"[^\"]*\"' $skels 2>/dev/null | tr '\\n' ' '; echo; "
      "tail -25 $log 2>/dev/null; echo @@@COUNTS; "
      "grep -c 'MODEL ' $log 2>/dev/null; "
      "grep -c 'OFFSET MISMATCH' $log 2>/dev/null; "
      'wc -c < $log 2>/dev/null',
      timeout: const Duration(seconds: 15),
    );
    return Ok(r.out);
  }

  Future<String> _rawTail() async {
    final r = await _shell('tail -25 ${ModelSwapPaths.logPath} 2>/dev/null');
    return r.out;
  }
}
