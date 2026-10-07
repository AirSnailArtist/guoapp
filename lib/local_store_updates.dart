part of 'local_store.dart';

extension FollowUpdatesStore on LocalStore {
  List<FollowSubscription> get followSubscriptions {
    if (_followSubscriptionCache != null) return _followSubscriptionCache!;
    final groups = <String, List<Drama>>{};
    for (final drama in favorites.where((d) => d.source == 'hongguo')) {
      (groups[followSeriesKey(drama)] ??= []).add(drama);
    }
    return _followSubscriptionCache = [
      for (final group in groups.entries)
        FollowSubscription(group.key, group.value),
    ];
  }

  FollowSeriesState followSeriesState(FollowSubscription subscription) {
    if (_followSeries.containsKey(subscription.key)) {
      return _followSeries[subscription.key]!;
    }
    final known = <String, Drama>{
      for (final d in subscription.members) d.id: d,
    };
    final notices = <String, FollowUpdate>{};
    for (final member in subscription.members) {
      final state = following(member.id);
      if (state == null) continue;
      if (state.newEpisodes > 0) {
        final id = 'episodes:${member.id}';
        notices[id] = FollowUpdate(
          id: id,
          drama: member,
          foundAt: DateTime.fromMillisecondsSinceEpoch(0),
          from: state.readEpisodes! + 1,
          to: state.knownEpisodes,
        );
      }
      for (final old in state.seriesSeasons.values) {
        final drama = Drama(id: old.id, source: 'hongguo', title: old.title);
        known[drama.id] = drama;
        final id = 'season:${drama.id}';
        notices[id] = FollowUpdate(
          id: id,
          drama: drama,
          foundAt: DateTime.fromMillisecondsSinceEpoch(0),
          existing: true,
          read: old.read,
        );
      }
    }
    for (final d in subscription.match(history.map((entry) => entry.drama))) {
      if (watched(d.id)?.position != null && watched(d.id)!.position > 0) {
        known[d.id] = d;
      }
    }
    return FollowSeriesState(known: known, updates: notices);
  }

  List<FollowSubscription> get updatedSubscriptions =>
      followSubscriptions
          .where((group) => followSeriesState(group).unread.isNotEmpty)
          .toList()
        ..sort(
          (a, b) => followSeriesState(b).unread.first.foundAt.compareTo(
            followSeriesState(a).unread.first.foundAt,
          ),
        );

  int get followUpdateCount => updatedSubscriptions.length;
  bool hasFollowUpdates(String id) {
    final drama = _favorites[id];
    if (drama == null) return false;
    if (drama.source != 'hongguo') return following(id)?.hasUpdates == true;
    final group = followSubscriptions
        .where((group) => group.key == followSeriesKey(drama))
        .firstOrNull;
    return group != null && followSeriesState(group).unread.isNotEmpty;
  }

  Map<String, FollowSeriesState> _activeFollowSeries() => {
    for (final group in followSubscriptions)
      group.key: followSeriesState(group),
  };
  String _encodeFollowSeries(Map<String, FollowSeriesState> states) =>
      jsonEncode({
        for (final entry in states.entries) entry.key: entry.value.toJson(),
      });

  Future<void> saveFollowCheck(
    String key,
    Iterable<Drama> rows, {
    required bool complete,
    required int epoch,
    String warning = '',
    DateTime? now,
  }) => _queue(() async {
    if (locked || epoch != profileEpoch) return;
    final group = followSubscriptions
        .where((group) => group.key == key)
        .firstOrNull;
    if (group == null) return;
    final states = _activeFollowSeries();
    states[key] = followSeriesState(group).observe(
      group,
      rows,
      now ?? DateTime.now(),
      complete: complete,
      warning: warning,
      watched: history
          .where((w) => w.position > 0)
          .map((w) => w.drama.id)
          .toSet(),
    );
    await _commit({
      _key('followUpdatesV1'): _encodeFollowSeries(states),
    }, trackSync: false);
    _loadLibrary();
    _notify();
  });

  Future<void> acknowledgeFollowUpdate(String key, String eventId) {
    final epoch = profileEpoch;
    return _queue(() async {
      if (locked || epoch != profileEpoch) return;
      final group = followSubscriptions
          .where((group) => group.key == key)
          .firstOrNull;
      if (group == null) return;
      final states = _activeFollowSeries();
      states[key] = followSeriesState(group).acknowledge(eventId: eventId);
      final event = states[key]!.updates[eventId];
      final legacy = Map<String, FollowState>.of(_followStates);
      if (event != null) {
        for (final id in legacy.keys.toList()) {
          if (event.newSeason) {
            legacy[id] = legacy[id]!.markSeriesSeasonRead(event.drama.id);
          } else if (id == event.drama.id) {
            legacy[id] = legacy[id]!.copyWith(readEpisodes: event.to);
          }
        }
      }
      await _commit({
        _key('followUpdatesV1'): _encodeFollowSeries(states),
        _key('followStates'): _encodeFollowStates(legacy),
      });
      _loadLibrary();
      _notify();
    });
  }
}
