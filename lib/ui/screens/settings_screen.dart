import 'package:flutter/material.dart';

import '../../backend.dart';
import '../tokens.dart';
import '../widgets/foundation.dart';

/// G 设置 / 关于：后端状态 + 版本信息 + 权限说明。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.backend});

  final YuiHelperBackend backend;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  SwapStatus? _status;
  String? _pingText;
  bool? _pingOk;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ping = await widget.backend.ping();
    final status = await widget.backend.modelSwap.status();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = status;
      switch (ping) {
        case Ok<bool>():
          _pingOk = true;
          _pingText = '正常';
        case Err<bool>(:final error):
          _pingOk = false;
          _pingText = error.userMessage;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppPageBody(
      children: [
        AppPageHeader(
          title: '设置',
          subtitle: '后端状态、版本与权限说明',
          trailing: IconCircleButton(
            icon: Icons.refresh_rounded,
            onPressed: _busy ? null : _refresh,
          ),
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CardHeader(
                title: '游戏连接',
                trailing: SizedBox(
                  width: 18,
                  height: 18,
                  child: _busy
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : null,
                ),
              ),
              _kv('引擎地址', widget.backend.endpoint),
              const SizedBox(height: 8),
              _kv(
                '引擎状态',
                _pingText ?? '读取中…',
                color: _pingOk == null
                    ? AppColors.ink2
                    : _pingOk!
                        ? AppColors.successInk
                        : AppColors.danger,
              ),
              const SizedBox(height: 12),
              const Text(
                '领取奖励与装配想象力走游戏内离线引擎的本地接口；游戏必须在前台。',
                style: TextStyle(fontSize: 10, height: 1.5, color: AppColors.ink3),
              ),
            ],
          ),
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CardHeader(title: '设备环境'),
              EnvRow(
                label: 'root',
                state: _status?.hasRoot,
                value: _status == null
                    ? '读取中'
                    : _status!.hasRoot
                        ? '已授权'
                        : '未授权',
              ),
              EnvRow(
                label: '游戏进程',
                state: _status?.gameRunning,
                value: _status == null
                    ? '读取中'
                    : _status!.gameRunning
                        ? '运行中 ${_status!.gamePid ?? ''}'
                        : '没在跑',
              ),
              EnvRow(
                label: '注入器',
                state: _status == null || !_status!.injectorRunning ? null : true,
                value: _status == null
                    ? '读取中'
                    : _status!.injectorRunning
                        ? '运行中 ${_status!.injectorPid ?? ''}'
                        : '未启动',
              ),
              const SizedBox(height: 8),
              const Text(
                '换模型需要 root（su）；root 未授权时只影响换模型，其余功能照常。',
                style: TextStyle(fontSize: 10, height: 1.5, color: AppColors.ink3),
              ),
            ],
          ),
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CardHeader(title: '关于'),
              _kv('版本', '0.1.0+1'),
              const SizedBox(height: 6),
              _kv('包名', 'com.yuihelper.next'),
              const SizedBox(height: 6),
              _kv('设计稿', 'design/*.html'),
              const SizedBox(height: 10),
              const Text(
                '界面按 design/ui-system.html 的令牌与组件实现；'
                '后端已移植：领取奖励、装配想象力、换模型。'
                '数值写入、技能全满、更新检查不在本期范围。',
                style: TextStyle(fontSize: 10, height: 1.6, color: AppColors.ink2),
              ),
            ],
          ),
        ),
        const AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CardHeader(title: '权限说明'),
              Text(
                '· INTERNET：只用于访问游戏进程自己开的 127.0.0.1:18680。\n'
                '· root：仅换模型需要（部署注入器 / 写入规则 / 读写枚举）。\n'
                '· 所有修改都经游戏本地引擎的存档接口，失败会如实报错，不静默吞掉。',
                style: TextStyle(fontSize: 10, height: 1.75, color: AppColors.ink2),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(String label, String value, {Color? color}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.ink3),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: color ?? AppColors.ink,
            ),
          ),
        ),
      ],
    );
  }
}
