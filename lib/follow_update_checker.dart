import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'follow_updates.dart';
import 'local_store.dart';
import 'models.dart';

class FollowUpdateChecker extends ChangeNotifier {
  FollowUpdateChecker(
    AppRepository repository,
    this.store, {
    this.foregroundBusy,
    DateTime Function()? clock,
  }) : repository = repository.followRepository(),
       clock = clock ?? DateTime.now;
  final AppRepository repository;
  final LocalStore store;
  final bool Function()? foregroundBusy;
  final DateTime Function() clock;
  Timer? _timer;
  bool _disposed = false;
  bool paused = false;
  bool busy = false;
  int checked = 0;
  int total = 0;
  int _generation = 0;
  String error = '';
  String currentTitle = '';

  int? _epoch;
  String? _checkingKey;
  void _storeChanged() {
    if (busy &&
        (_epoch != store.profileEpoch ||
            store.locked ||
            !store.followSubscriptions.any(
              (group) => group.key == _checkingKey,
            ))) {
      unawaited(cancel());
    }
  }

  void start() {
    store.removeListener(_storeChanged);
    store.addListener(_storeChanged);
    _timer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(checkNow()),
    );
    unawaited(checkNow());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> cancel() async {
    _generation++;
    await repository.cancelFollowChecks();
  }

  void setPaused(bool value) {
    paused = value;
    if (value) {
      unawaited(cancel());
    } else {
      unawaited(checkNow());
    }
  }

  bool _valid(int generation, int epoch) =>
      !_disposed &&
      !paused &&
      !store.locked &&
      generation == _generation &&
      epoch == store.profileEpoch;

  Future<void> checkNow({bool force = false, String? onlyKey}) async {
    if (_disposed ||
        paused ||
        busy ||
        store.locked ||
        !force && (foregroundBusy?.call() ?? false)) {
      return;
    }
    final now = clock();
    final groups =
        store.followSubscriptions
            .where(
              (group) =>
                  (onlyKey == null || group.key == onlyKey) &&
                  (force || store.followSeriesState(group).due(now)),
            )
            .toList()
          ..sort(
            (a, b) => (store.followSeriesState(a).attemptedAt ?? DateTime(2000))
                .compareTo(
                  store.followSeriesState(b).attemptedAt ?? DateTime(2000),
                ),
          );
    final selected = force ? groups : groups.take(8).toList();
    if (selected.isEmpty) return;
    final generation = ++_generation, epoch = store.profileEpoch;
    _epoch = epoch;
    busy = true;
    checked = 0;
    total = selected.length;
    error = '';
    _notify();
    try {
      for (final group in selected) {
        if (!_valid(generation, epoch) ||
            !force && (foregroundBusy?.call() ?? false)) {
          break;
        }
        if (!store.followSubscriptions.any(
          (current) => current.key == group.key,
        )) {
          continue;
        }
        _checkingKey = group.key;
        currentTitle = group.title;
        _notify();
        final rows = <String, Drama>{};
        final warnings = <String>[];
        try {
          final page = await repository.catalog(
            'hongguo',
            query: group.title,
            force: true,
          );
          if (!_valid(generation, epoch)) break;
          for (final drama in group.match(page.items)) {
            rows[drama.id] = drama;
          }
          if (page.warning.isNotEmpty) warnings.add(page.warning);
          if (page.hasMore || page.localSearch) warnings.add('搜索结果未完整返回');
          final bySeason = <int, List<Drama>>{};
          for (final drama in rows.values) {
            final season = followSeasonNumber(drama);
            (bySeason[season] ??= []).add(drama);
          }
          for (final entries in bySeason.values.where(
            (entries) => entries.length > 1,
          )) {
            final known = store.followSeriesState(group).known;
            final unknown = entries
                .where((d) => !known.containsKey(d.id))
                .toList();
            if (unknown.isNotEmpty) {
              warnings.add('存在同名同季的多个版本，暂不自动关联');
              for (final drama in unknown) {
                rows.remove(drama.id);
              }
            }
          }
          for (final drama in group.members) {
            if (!_valid(generation, epoch) ||
                !force && (foregroundBusy?.call() ?? false)) {
              break;
            }
            try {
              final detail = await repository.followDetail(drama);
              if (!_valid(generation, epoch)) break;
              rows[drama.id] = detail.drama;
              if (detail.warning.isNotEmpty) warnings.add(detail.warning);
            } catch (_) {
              if (!_valid(generation, epoch)) break;
              warnings.add('部分分集检查失败，稍后重试');
            }
          }
        } catch (_) {
          if (!_valid(generation, epoch)) break;
          warnings.add('站点暂不可用，稍后重试');
        }
        if (!_valid(generation, epoch) ||
            !force && (foregroundBusy?.call() ?? false)) {
          break;
        }
        try {
          await store.saveFollowCheck(
            group.key,
            rows.values,
            complete: warnings.isEmpty,
            epoch: epoch,
            warning: warnings.toSet().join('；'),
            now: clock(),
          );
        } catch (_) {
          error = '更新提醒未能保存，请重试';
          break;
        }
        checked++;
        _notify();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      busy = false;
      currentTitle = '';
      _notify();
    }
  }

  @override
  void dispose() {
    store.removeListener(_storeChanged);
    _disposed = true;
    _timer?.cancel();
    unawaited(cancel());
    super.dispose();
  }
}
