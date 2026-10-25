import 'package:flutter/material.dart';

import '../backend.dart';
import 'screens/equip_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/tasks_screen.dart';
import 'tokens.dart';
import 'widgets/foundation.dart';

class YuiHelperApp extends StatelessWidget {
  const YuiHelperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YuiHelper Next',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const AppShell(),
    );
  }
}

/// 一级导航：胶囊 Tab 栏 + IndexedStack。
///
/// 设计稿（design/ui-system.html 7.3）规定 3–4 个一级目的地；
/// 这里 4 个：数值（工作台）/ 装备 / 任务 / 设置；二级页（数值修改、
/// 换模型、领取所有奖励）由一级页 push 出来。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final YuiHelperBackend _backend = YuiHelperBackend();
  int _index = 0;

  void _switchTab(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: IndexedStack(
                index: _index,
                children: [
                  HomeScreen(backend: _backend, onSwitchTab: _switchTab),
                  EquipScreen(backend: _backend),
                  TasksScreen(backend: _backend),
                  SettingsScreen(backend: _backend),
                ],
              ),
            ),
          ),
          Positioned(
            left: 21,
            right: 21,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PillTabBar(
                  items: const [
                    PillTabItem(Icons.tune_rounded, '数值'),
                    PillTabItem(Icons.shield_outlined, '装备'),
                    PillTabItem(Icons.checklist_rounded, '任务'),
                    PillTabItem(Icons.settings_outlined, '设置'),
                  ],
                  index: _index,
                  onChanged: _switchTab,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
