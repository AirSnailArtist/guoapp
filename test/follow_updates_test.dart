import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/follow_state.dart';
import 'package:duanju_app/follow_updates.dart';
import 'package:duanju_app/follow_update_checker.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Drama season(int value, {int episodes = 10, String series = '合成万妖'}) => Drama(
  id: 'hongguo:$series-$value',
  source: 'hongguo',
  title: '$series 第$value季',
  episodes: episodes,
);

class UpdatesRepository extends FixtureRepository {
  List<Drama> rows = [];
  String warning = '';
  Completer<CatalogPage>? pending;
  int calls = 0, cancels = 0;
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    calls++;
    if (pending != null) return pending!.future;
    return CatalogPage(rows, warning: warning);
  }

  @override
  Future<DramaDetail> followDetail(Drama drama) async =>
      DramaDetail(rows.where((d) => d.id == drama.id).firstOrNull ?? drama, [
        Episode({'currentEpisode': 1}, 1),
      ]);
  @override
  Future<void> cancelFollowChecks() async {
    cancels++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<LocalStore> store() async {
    SharedPreferences.setMockInitialValues({});
    final s = testStore(await SharedPreferences.getInstance());
    addTearDown(s.dispose);
    return s;
  }

  test(
    'series baseline, future season, duplicate result and monotonic episodes',
    () {
      final anchor = season(10),
          group = FollowSubscription(followSeriesKey(season(10)), [anchor]);
      final now = DateTime.utc(2026, 10, 6);
      var state = FollowSeriesState(known: {anchor.id: anchor});
      state = state.observe(group, [anchor, season(11)], now, complete: true);
      expect(state.unread.single.existing, isTrue);
      state = state.acknowledge(eventId: state.unread.single.id);
      state = state.observe(
        group,
        [anchor, season(11), season(12)],
        now.add(const Duration(hours: 6)),
        complete: true,
      );
      expect(state.unread.single.drama.id, season(12).id);
      expect(state.unread.single.existing, isFalse);
      state = state.observe(
        group,
        [anchor, season(11), season(12)],
        now,
        complete: true,
      );
      expect(state.unread.length, 1);
      state = state.observe(
        group,
        [season(10, episodes: 12)],
        now,
        complete: true,
      );
      expect(state.unread.where((e) => !e.newSeason).single.from, 11);
      state = state.observe(
        group,
        [season(10, episodes: 5)],
        now,
        complete: true,
      );
      expect(state.known[anchor.id]!.episodes, 12);
    },
  );

  test(
    'watching one episode leaves the remainder unread, known acknowledgements never revive',
    () {
      final anchor = season(1),
          group = FollowSubscription(followSeriesKey(anchor), [anchor]);
      var state = FollowSeriesState(known: {anchor.id: anchor}, baseline: true)
          .observe(
            group,
            [season(1, episodes: 13)],
            DateTime.now(),
            complete: true,
          );
      WatchEntry watch(int episode) => WatchEntry(
        drama: anchor,
        episode: episode,
        position: 3,
        duration: 60,
        updatedAt: DateTime.now(),
      );
      state = state.acknowledge(watch: watch(11));
      expect(state.unread.single.from, 12);
      state = state.acknowledge(eventId: state.unread.single.id);
      state = state.acknowledge(watch: watch(12));
      expect(state.unread, isEmpty);
    },
  );

  test('partial failures retain notifications and last successful time', () {
    final anchor = season(1),
        group = FollowSubscription(followSeriesKey(anchor), [anchor]);
    final now = DateTime.utc(2026, 10, 6);
    var state = FollowSeriesState(
      known: {anchor.id: anchor},
      baseline: true,
      checkedAt: now,
    ).observe(group, [season(2)], now, complete: true);
    state = state.observe(
      group,
      [],
      now.add(const Duration(hours: 6)),
      complete: false,
      warning: '部分结果',
    );
    expect(state.unread.length, 1);
    expect(state.checkedAt, now);
    expect(state.error, '部分结果');
    expect(state.due(now.add(const Duration(hours: 6, minutes: 2))), isFalse);
  });

  test(
    'only followed series are checked; multiple seasons share one request and persist',
    () async {
      final s = await store();
      await s.setFollowStatus(season(9), FollowStatus.watched);
      await s.setFollowStatus(season(10), FollowStatus.watched);
      final repository = UpdatesRepository()
        ..rows = [season(9), season(10), season(11), season(2, series: '无关剧')];
      final checker = FollowUpdateChecker(repository, s);
      addTearDown(checker.dispose);
      await checker.checkNow(force: true);
      expect(repository.calls, 1);
      expect(s.followUpdateCount, 1);
      final restarted = testStore(await SharedPreferences.getInstance());
      addTearDown(restarted.dispose);
      expect(restarted.followUpdateCount, 1);
      await checker.checkNow(force: true);
      expect(s.updatedSubscriptions.length, 1);
      final event = s
          .followSeriesState(s.updatedSubscriptions.single)
          .unread
          .single;
      expect(event.drama.id, season(11).id);
      final backup = await s.exportBackup();
      expect(
        (jsonDecode(backup)['libraries']['default'] as Map)['followUpdatesV1'],
        isNotEmpty,
      );
      await s.importBackup(backup);
      expect(s.followUpdateCount, 1);
      await s.toggleFavorite(season(9));
      expect(s.followUpdateCount, 1);
      await s.toggleFavorite(season(10));
      expect(s.followUpdateCount, 0);
      await checker.checkNow(force: true);
      expect(repository.calls, 2);
    },
  );

  test(
    'read legacy season stays read and a new season is acknowledged only by actual playback',
    () async {
      final s = await store();
      await s.toggleFavorite(season(10));
      await s.refreshDramas([season(10), season(11)]);
      await s.markSeriesSeasonRead(season(10).id, season(11).id);
      final repository = UpdatesRepository()
        ..rows = [season(10), season(11), season(12)];
      final checker = FollowUpdateChecker(repository, s);
      addTearDown(checker.dispose);
      await checker.checkNow(force: true);
      expect(
        s
            .followSeriesState(s.updatedSubscriptions.single)
            .unread
            .single
            .drama
            .id,
        season(12).id,
      );
      await s.saveWatch(
        WatchEntry(
          drama: season(12),
          episode: 1,
          position: 0,
          duration: 60,
          updatedAt: DateTime.now(),
        ),
      );
      expect(s.followUpdateCount, 1);
      await s.saveWatch(
        WatchEntry(
          drama: season(12),
          episode: 1,
          position: 2,
          duration: 60,
          updatedAt: DateTime.now(),
        ),
      );
      expect(s.followUpdateCount, 0);
    },
  );

  test('cancel and unsubscribe discard in-flight results', () async {
    final s = await store();
    await s.toggleFavorite(season(10));
    final repository = UpdatesRepository()..pending = Completer<CatalogPage>();
    final checker = FollowUpdateChecker(repository, s);
    addTearDown(checker.dispose);
    final run = checker.checkNow(force: true);
    await Future<void>.delayed(Duration.zero);
    await checker.cancel();
    await s.toggleFavorite(season(10));
    repository.pending!.complete(CatalogPage([season(11)]));
    await run;
    expect(s.followUpdateCount, 0);
    expect(repository.cancels, 1);
  });

  test(
    'profile switches reject previous results, automatic checks respect foreground and suspension',
    () async {
      final s = await store();
      await s.saveProfile(
        id: 'default',
        name: '管理员',
        sources: ['hongguo'],
        download: true,
        pin: '123456',
      );
      await s.saveProfile(name: '访客', sources: ['hongguo'], download: false);
      final guestId = s.profiles.last.id;
      await s.toggleFavorite(season(10));
      final repository = UpdatesRepository()
        ..pending = Completer<CatalogPage>();
      final checker = FollowUpdateChecker(
        repository,
        s,
        foregroundBusy: () => true,
      );
      addTearDown(checker.dispose);
      checker.start();
      await checker.checkNow();
      expect(repository.calls, 0);
      final run = checker.checkNow(force: true);
      await Future<void>.delayed(Duration.zero);
      s.lock();
      repository.pending!.complete(CatalogPage([season(11)]));
      await run;
      await s.switchProfile(guestId);
      expect(s.followUpdateCount, 0);
      checker.setPaused(true);
      await checker.checkNow(force: true);
      expect(repository.calls, 1);
    },
  );

  test(
    'unknown duplicate season versions are not automatically linked',
    () async {
      final s = await store();
      await s.toggleFavorite(season(10));
      final copy = Drama(
        id: 'hongguo:other',
        source: 'hongguo',
        title: season(11).title,
        episodes: 10,
      );
      final repository = UpdatesRepository()
        ..rows = [season(11), copy, season(2, series: '其他万妖')];
      final checker = FollowUpdateChecker(repository, s);
      addTearDown(checker.dispose);
      await checker.checkNow(force: true);
      expect(s.followUpdateCount, 0);
      expect(
        s.followSeriesState(s.followSubscriptions.single).error,
        contains('同名'),
      );
    },
  );
}
