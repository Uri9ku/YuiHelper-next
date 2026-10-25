import 'dart:async';
import 'dart:convert';

import 'package:yui_helper_next/data/transport.dart';
import 'package:yui_helper_next/domain/result.dart';

/// 四个领取动作在假服务器上对应的路径。
const String kPullPath = '/api/user/pull';
const String kMissionPath = '/api/mission/receive';
const String kGiftPath = '/api/gift/receive';
const String kSeasonPath = '/api/season-reward/receive';
const String kEventCharPath = '/api/event/character/reward/receive';

/// 「引擎活着吗」的探针路径（只读，不改存档）。
const String kPingPath = '/api/mission/refresh';

/// 按路径排队应答的传输层替身。
///
/// 同一路径的排队里只剩一条时，它会**一直重放**那一条 —— 零增长、
/// 表恒为空这类场景正好需要这样。
final class ScriptedTransport implements Transport {
  final List<String> paths = [];
  final List<String> bodies = [];

  /// 设了就先等它。用来制造「请求还在飞」的窗口，测双击防护。
  Completer<void>? gate;

  /// 设了就让 `post` 直接抛出来。用来模拟"某层忘了把异常接成 Result"。
  Object? throwThis;

  final Map<String, List<String>> _queue = {};

  void script(String path, String response) =>
      (_queue[path] ??= <String>[]).add(response);

  void scriptAll(String path, List<String> responses) =>
      (_queue[path] ??= <String>[]).addAll(responses);

  int countFor(String path) => paths.where((p) => p == path).length;

  List<String> bodiesFor(String path) => [
        for (var i = 0; i < paths.length; i++)
          if (paths[i] == path) bodies[i],
      ];

  @override
  Future<Result<HttpReply>> post(String path, String bodyJson) async {
    final boom = throwThis;
    if (boom != null) throw boom;

    paths.add(path);
    bodies.add(bodyJson);

    final pending = gate;
    if (pending != null) await pending.future;

    final queue = _queue[path];
    if (queue == null || queue.isEmpty) {
      return Err(AppError(
        kind: AppErrorKind.badJson,
        userMessage: '游戏回了一段看不懂的内容',
        detail: '测试没给 $path 准备应答',
      ));
    }
    // 先取出队首再消费：只剩一条时它会一直重放。
    final response = queue.first;
    if (queue.length > 1) queue.removeAt(0);
    return Ok(HttpReply(200, response));
  }
}

/// 造一份 `/api/user/pull` 形状的响应。没传的表不会出现（服务端只回变动的表）。
String pullOf({
  List<Map<String, Object?>>? mission,
  List<Map<String, Object?>>? gift,
  List<Map<String, Object?>>? seasonReward,
  List<Map<String, Object?>>? eventCharacterReward,
}) =>
    jsonEncode({
      'code': 0,
      'table': {
        'replace': {
          'mission': ?mission,
          'gift': ?gift,
          'seasonReward': ?seasonReward,
          'eventCharacterReward': ?eventCharacterReward,
        },
      },
    });

String okWith({Map<String, Object?>? put}) => jsonEncode({
      'code': 0,
      'table': {'replace': <String, Object?>{}, 'put': ?put},
    });

List<Map<String, Object?>> missionsOf(List<int> states) => [
      for (var i = 0; i < states.length; i++)
        {
          'userId': 1,
          'missionId': 15000000001 + i,
          'state': states[i],
          'progress': 1,
        },
    ];

List<Map<String, Object?>> seasonOf(Map<int, int> acquired) => [
      for (final entry in acquired.entries)
        {'seasonRewardId': entry.key, 'acquiredCount': entry.value},
    ];

