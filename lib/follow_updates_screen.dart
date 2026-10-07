import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'follow_update_checker.dart';
import 'follow_updates.dart';
import 'local_store.dart';
import 'playback_launch_screen.dart';
import 'remote_widgets.dart';
import 'widgets.dart';

class FollowUpdatesScreen extends StatelessWidget {
  const FollowUpdatesScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.checker,
    this.seriesKey,
  });
  final AppRepository repository;
  final LocalStore store;
  final FollowUpdateChecker checker;
  final String? seriesKey;

  Future<void> _open(BuildContext context, FollowSubscription group) async {
    final epoch = store.profileEpoch;
    final state = store.followSeriesState(group);
    final event = await showDialog<FollowUpdate>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(group.title),
        content: SizedBox(
          width: 560,
          height: 280,
          child: ListView(
            children: [
              for (final entry in state.unread.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: RemoteTarget(
                    autofocus: entry.$1 == 0,
                    onPressed: () => Navigator.pop(dialogContext, entry.$2),
                    label: '${entry.$2.drama.title}，${entry.$2.label}',
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.$2.drama.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            entry.$2.label,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const Text(
                            '确认后播放新内容',
                            style: TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          RemoteButton(
            label: '全部已知晓',
            onPressed: () async {
              if (epoch != store.profileEpoch) {
                Navigator.pop(dialogContext);
                return;
              }
              for (final event in state.unread) {
                if (epoch != store.profileEpoch) break;
                await store.acknowledgeFollowUpdate(group.key, event.id);
              }
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
          ),
          RemoteButton(
            label: '返回',
            onPressed: () => Navigator.pop(dialogContext),
          ),
        ],
      ),
    );
    if (event == null || !context.mounted || epoch != store.profileEpoch) {
      return;
    }
    await checker.cancel();
    if (!context.mounted) return;
    await openPlaybackDirectly(
      context,
      drama: event.drama,
      repository: repository,
      store: store,
      initialEpisode: event.newSeason ? 1 : event.from,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([store, checker]),
    builder: (context, _) {
      final all = store.followSubscriptions;
      final groups = store.updatedSubscriptions
          .where((group) => seriesKey == null || group.key == seriesKey)
          .toList();
      final checked =
          all
              .map((group) => store.followSeriesState(group).checkedAt)
              .whereType<DateTime>()
              .toList()
            ..sort();
      final failures = all
          .where((group) => store.followSeriesState(group).error.isNotEmpty)
          .length;
      final television = AppLayout.isTelevision(context);
      return Scaffold(
        appBar: AppBar(
          title: Text('追剧更新 · ${groups.length}'),
          actions: [
            if (television)
              RemoteButton(
                key: const ValueKey('check-follow-updates'),
                label: checker.busy ? '停止检查' : '检查更新',
                icon: checker.busy ? Icons.stop_rounded : Icons.refresh_rounded,
                onPressed: checker.busy
                    ? checker.cancel
                    : () => checker.checkNow(force: true, onlyKey: seriesKey),
              )
            else
              TextButton.icon(
                key: const ValueKey('check-follow-updates'),
                onPressed: checker.busy
                    ? checker.cancel
                    : () => checker.checkNow(force: true, onlyKey: seriesKey),
                icon: Icon(
                  checker.busy ? Icons.stop_rounded : Icons.refresh_rounded,
                ),
                label: Text(checker.busy ? '停止' : '检查更新'),
              ),
            const SizedBox(width: 12),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    checker.busy
                        ? '检查 ${checker.checked + 1}/${checker.total} · ${checker.currentTitle}'
                        : checker.error.isNotEmpty
                        ? checker.error
                        : all.isEmpty
                        ? '加入追剧后，会持续关注后续季和新增集数。'
                        : '${checked.isEmpty ? '尚未完成检查' : '最近成功检查：${checked.last.toLocal().toString().substring(0, 16)}'}${failures > 0 ? ' · $failures 个系列待重试' : ''}\n应用运行时自动检查，关闭后下次打开补查。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              Expanded(
                child: groups.isEmpty
                    ? StatusPanel(
                        title: all.isEmpty ? '还没有追剧' : '暂无未读更新',
                        message: all.isEmpty
                            ? '在剧集详情中加入追剧，即可关注整个系列。'
                            : '可以点击“检查更新”。已知晓的更新仍会保留观看进度。',
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final columns = (constraints.maxWidth / 260)
                              .floor()
                              .clamp(1, 6);
                          return RemoteGrid(
                            itemKeys: groups.map((group) => group.key).toList(),
                            columns: columns,
                            itemExtent: 210,
                            padding: const EdgeInsets.all(18),
                            autofocus: true,
                            itemBuilder: (context, index, node, onFocus) {
                              final group = groups[index],
                                  events = store
                                      .followSeriesState(groups[index])
                                      .unread;
                              final ids = group
                                  .match(
                                    store.history.map((entry) => entry.drama),
                                  )
                                  .map((d) => d.id)
                                  .toSet();
                              final watch = store.history
                                  .where(
                                    (entry) => ids.contains(entry.drama.id),
                                  )
                                  .firstOrNull;
                              return RemoteTarget(
                                key: ValueKey('follow-update-${group.key}'),
                                focusNode: node,
                                onFocus: onFocus,
                                onPressed: () => _open(context, group),
                                label: '${group.title}，${events.first.label}',
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.notifications_active_rounded,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                          const Spacer(),
                                          Text('${events.length} 项待看'),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        group.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 19,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        watch == null
                                            ? '关注至第 ${group.season} 季'
                                            : '看到第 ${followSeasonNumber(watch.drama)} 季 · 第 ${watch.episode} 集',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        events.first.label,
                                        maxLines: 2,
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
