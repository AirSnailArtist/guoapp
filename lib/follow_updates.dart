import 'dart:math';

import 'catalog_sort.dart';
import 'hongguo_series.dart';
import 'models.dart';

int followSeasonNumber(Drama drama) => hongguoSeriesInfo(drama)?.season ?? 1;

String followSeriesKey(Drama drama) {
  final info = hongguoSeriesInfo(drama);
  return '${drama.source}|${info?.key ?? normalizedSearchText(drama.title)}|${info?.unit ?? '季'}';
}

class FollowSubscription {
  FollowSubscription(this.key, this.members) {
    members.sort(
      (a, b) => (hongguoSeriesInfo(b)?.season ?? 1).compareTo(
        hongguoSeriesInfo(a)?.season ?? 1,
      ),
    );
  }
  final String key;
  final List<Drama> members;
  Drama get anchor => members.first;
  String get title => hongguoSeriesInfo(anchor)?.baseTitle ?? anchor.title;
  int get season => hongguoSeriesInfo(anchor)?.season ?? 1;
  List<Drama> match(Iterable<Drama> dramas) {
    final info = hongguoSeriesInfo(anchor);
    final base = info?.key ?? normalizedSearchText(anchor.title);
    final unit = info?.unit ?? '季';
    final ids = members.map((member) => member.id).toSet();
    final result = <String, Drama>{anchor.id: anchor};
    for (final drama in dramas) {
      if (drama.source != anchor.source) continue;
      final candidate = hongguoSeriesInfo(drama, unit: unit);
      if (ids.contains(drama.id) ||
          candidate != null &&
              candidate.key == base &&
              candidate.unit == unit) {
        result[drama.id] = drama;
      }
    }
    return result.values.toList();
  }
}

class FollowUpdate {
  const FollowUpdate({
    required this.id,
    required this.drama,
    required this.foundAt,
    this.from = 0,
    this.to = 0,
    this.existing = false,
    this.read = false,
  });
  final String id;
  final Drama drama;
  final DateTime foundAt;
  final int from;
  final int to;
  final bool existing;
  final bool read;
  bool get newSeason => from == 0;
  String get label => newSeason
      ? '${existing ? '后续季可看' : '发现新季'} · 第 ${hongguoSeriesInfo(drama)?.season ?? 1} ${hongguoSeriesInfo(drama)?.unit ?? '季'}'
      : '${existing ? '发现可看集数' : '新增集数'} · 第 $from–$to 集';
  FollowUpdate markRead() => FollowUpdate(
    id: id,
    drama: drama,
    foundAt: foundAt,
    from: from,
    to: to,
    existing: existing,
    read: true,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'drama': drama.toJson(),
    'foundAt': foundAt.toIso8601String(),
    'from': from,
    'to': to,
    'existing': existing,
    'read': read,
  };
  factory FollowUpdate.fromJson(Map<String, dynamic> json) {
    final drama = Drama.fromJson(
      Map<String, dynamic>.from(json['drama'] as Map),
    );
    final from = intValue(json['from']), to = intValue(json['to']);
    if (drama.source != 'hongguo' ||
        from < 0 ||
        to < from ||
        to > 100000 ||
        json['id'] is! String) {
      throw const FormatException('更新通知无效');
    }
    return FollowUpdate(
      id: json['id'] as String,
      drama: drama,
      foundAt: DateTime.parse(json['foundAt'] as String),
      from: from,
      to: to,
      existing: json['existing'] == true,
      read: json['read'] == true,
    );
  }
}

class FollowSeriesState {
  const FollowSeriesState({
    this.known = const {},
    this.updates = const {},
    this.baseline = false,
    this.attemptedAt,
    this.checkedAt,
    this.error = '',
    this.failures = 0,
  });
  final Map<String, Drama> known;
  final Map<String, FollowUpdate> updates;
  final bool baseline;
  final DateTime? attemptedAt;
  final DateTime? checkedAt;
  final String error;
  final int failures;
  List<FollowUpdate> get unread =>
      updates.values.where((event) => !event.read).toList()
        ..sort((a, b) => b.foundAt.compareTo(a.foundAt));
  bool due(DateTime now) {
    if (error.isNotEmpty && attemptedAt != null) {
      return now.difference(attemptedAt!) >=
          Duration(minutes: min(360, 5 * (1 << min(failures, 6))));
    }
    return checkedAt == null ||
        now.difference(checkedAt!) >= const Duration(hours: 6);
  }

  FollowSeriesState observe(
    FollowSubscription subscription,
    Iterable<Drama> rows,
    DateTime now, {
    required bool complete,
    String warning = '',
    Set<String> watched = const {},
    bool recordAttempt = true,
  }) {
    final next = Map<String, Drama>.of(known);
    final notices = Map<String, FollowUpdate>.of(updates);
    for (final drama in subscription.match(rows)) {
      final previous = next[drama.id];
      final count = max(previous?.episodes ?? 0, drama.episodes);
      next[drama.id] = Drama.fromJson({
        ...(previous?.merge(drama) ?? drama).toJson(),
        'episodes': count,
      });
      final season = hongguoSeriesInfo(drama)?.season ?? 1;
      if (previous == null &&
          season > subscription.season &&
          !watched.contains(drama.id)) {
        final id = 'season:${drama.id}';
        notices.putIfAbsent(
          id,
          () => FollowUpdate(
            id: id,
            drama: drama,
            foundAt: now,
            existing: !baseline,
          ),
        );
      } else if (previous != null &&
          previous.episodes > 0 &&
          count > previous.episodes) {
        final id = 'episodes:${drama.id}';
        final old = notices[id];
        notices[id] = FollowUpdate(
          id: id,
          drama: next[drama.id]!,
          foundAt: now,
          from: old != null && !old.read ? old.from : previous.episodes + 1,
          to: count,
          existing: !baseline,
        );
      }
    }
    return FollowSeriesState(
      known: next,
      updates: notices,
      baseline: baseline || complete,
      attemptedAt: recordAttempt ? now : attemptedAt,
      checkedAt: complete ? now : checkedAt,
      error: !recordAttempt
          ? error
          : complete
          ? ''
          : warning.isEmpty
          ? '本次检查未完成，稍后重试'
          : warning,
      failures: !recordAttempt
          ? failures
          : complete
          ? 0
          : min(failures + 1, 7),
    );
  }

  FollowSeriesState acknowledge({String? eventId, WatchEntry? watch}) {
    final notices = <String, FollowUpdate>{};
    for (final event in updates.values) {
      final match =
          watch != null &&
          !event.read &&
          watch.position > 0 &&
          watch.drama.id == event.drama.id &&
          (event.newSeason ||
              watch.episode >= event.from && watch.episode <= event.to);
      if (match && !event.newSeason && watch.episode < event.to) {
        notices[event.id] = FollowUpdate(
          id: event.id,
          drama: event.drama,
          foundAt: event.foundAt,
          from: watch.episode + 1,
          to: event.to,
          existing: event.existing,
        );
      } else {
        notices[event.id] = eventId == event.id || match
            ? event.markRead()
            : event;
      }
    }
    return FollowSeriesState(
      known: known,
      updates: notices,
      baseline: baseline,
      attemptedAt: attemptedAt,
      checkedAt: checkedAt,
      error: error,
      failures: failures,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'known': known.values.map((d) => d.toJson()).toList(),
    'updates': updates.values.map((e) => e.toJson()).toList(),
    'baseline': baseline,
    'attemptedAt': attemptedAt?.toIso8601String(),
    'checkedAt': checkedAt?.toIso8601String(),
    'error': error,
    'failures': failures,
  };
  factory FollowSeriesState.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        (json['known'] as List).length > 400 ||
        (json['updates'] as List).length > 800) {
      throw const FormatException('系列更新状态无效');
    }
    final dramas = (json['known'] as List).map(
      (row) => Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    );
    final events = (json['updates'] as List).map(
      (row) => FollowUpdate.fromJson(Map<String, dynamic>.from(row as Map)),
    );
    return FollowSeriesState(
      known: {for (final d in dramas) d.id: d},
      updates: {for (final e in events) e.id: e},
      baseline: json['baseline'] == true,
      attemptedAt: DateTime.tryParse(json['attemptedAt'] as String? ?? ''),
      checkedAt: DateTime.tryParse(json['checkedAt'] as String? ?? ''),
      error: json['error'] as String? ?? '',
      failures: intValue(json['failures']).clamp(0, 7),
    );
  }
}
