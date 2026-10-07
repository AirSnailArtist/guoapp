import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

class PreloadRepository extends FixtureRepository {
  final pending = <Completer<PlaybackPlan>>[];
  final released = <String>[];
  final requested = <(int, int, bool)>[];
  int cancelled = 0;

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    requested.add((episode.number, quality, online));
    final request = Completer<PlaybackPlan>();
    pending.add(request);
    return request.future;
  }

  @override
  Future<void> cancelPreload() async => cancelled++;

  @override
  Future<void> release(String session) async => released.add(session);
}

void main() {
  final drama = FixtureRepository.free;
  final episode = Episode({'id': '2'}, 2);
  const plan = PlaybackPlan(
    url: 'https://media.test/next.mp4',
    session: 'next',
    prefetchedBytes: 1024 * 1024,
  );

  PlaybackPreloadAction action(int duration, int position, int headroom) =>
      playbackPreloadAction(
        duration: Duration(milliseconds: duration),
        position: Duration(milliseconds: position),
        buffer: Duration(milliseconds: position + headroom),
      );

  test('short episodes prepare early with reachable TV buffer headroom', () {
    expect(action(80000, 1900, 5000), PlaybackPreloadAction.wait);
    expect(action(80000, 2000, 3000), PlaybackPreloadAction.prepare);
    expect(action(80000, 2000, 2999), PlaybackPreloadAction.wait);
    expect(action(120000, 2000, 4500), PlaybackPreloadAction.prepare);
    expect(action(4000, 1000, 3000), PlaybackPreloadAction.prepare);
    expect(action(80000, 79000, 1000), PlaybackPreloadAction.prepare);
    expect(action(80000, 80000, 0), PlaybackPreloadAction.pause);
    expect(action(0, 2000, 5000), PlaybackPreloadAction.pause);
  });

  test('low buffer pauses but the middle band keeps an existing request', () {
    expect(action(80000, 2000, 1499), PlaybackPreloadAction.pause);
    expect(action(80000, 2000, 1500), PlaybackPreloadAction.wait);
    expect(action(80000, 2000, 2500), PlaybackPreloadAction.wait);
    expect(action(240000, 2000, 5000), PlaybackPreloadAction.wait);
    expect(action(240000, 120000, 3000), PlaybackPreloadAction.prepare);
    expect(action(300000, 260000, 3000), PlaybackPreloadAction.prepare);
  });

  testWidgets('one prepared session transfers once and survives a pause', (
    tester,
  ) async {
    final repository = PreloadRepository();
    final preloader = PlaybackPreloader(repository);
    preloader.prepare(drama, episode);
    preloader.prepare(drama, episode);
    await tester.pump(const Duration(milliseconds: 200));
    expect(repository.requested, [(2, 0, false)]);
    repository.pending.single.complete(plan);
    await tester.pump();
    preloader.pause();
    expect(preloader.take(drama, episode), same(plan));
    expect(preloader.take(drama, episode), isNull);
    expect(repository.released, isEmpty);
    preloader.dispose();
  });

  testWidgets('cancelled late results release without replacing the new plan', (
    tester,
  ) async {
    final repository = PreloadRepository();
    final preloader = PlaybackPreloader(repository);
    preloader.prepare(drama, episode);
    await tester.pump(const Duration(milliseconds: 200));
    preloader.pause();
    expect(repository.cancelled, 1);
    preloader.prepare(drama, episode);
    await tester.pump(const Duration(milliseconds: 200));
    repository.pending.first.complete(plan);
    repository.pending.last.complete(
      const PlaybackPlan(url: 'https://media.test/new.mp4', session: 'new'),
    );
    await tester.pump();
    expect(repository.released, ['next']);
    expect(preloader.take(drama, episode)?.session, 'new');
    preloader.dispose();
  });

  testWidgets(
    'quality and online mode mismatches release the prepared session',
    (tester) async {
      for (final requested in [(720, false), (1080, true)]) {
        final repository = PreloadRepository();
        final preloader = PlaybackPreloader(repository);
        preloader.prepare(drama, episode, quality: 720, online: true);
        await tester.pump(const Duration(milliseconds: 200));
        expect(repository.requested, [(2, 720, true)]);
        repository.pending.single.complete(plan);
        await tester.pump();
        expect(
          preloader.take(
            drama,
            episode,
            quality: requested.$1,
            online: requested.$2,
          ),
          isNull,
        );
        await tester.pump();
        expect(repository.released, ['next']);
        preloader.dispose();
      }
    },
  );

  testWidgets('expired authorization is never handed to the player', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 7);
    final repository = PreloadRepository();
    final preloader = PlaybackPreloader(repository, now: () => now);
    preloader.prepare(drama, episode);
    await tester.pump(const Duration(milliseconds: 200));
    repository.pending.single.complete(
      PlaybackPlan(
        url: plan.url,
        session: plan.session,
        expiresAt: now.add(const Duration(seconds: 10)).millisecondsSinceEpoch,
      ),
    );
    await tester.pump();
    now = now.add(const Duration(seconds: 5));
    expect(preloader.take(drama, episode), isNull);
    await tester.pump();
    expect(repository.released, ['next']);
    preloader.dispose();
  });

  testWidgets('invalid results release and retries respect the backoff', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 7);
    final repository = PreloadRepository();
    final preloader = PlaybackPreloader(repository, now: () => now);
    preloader.prepare(drama, episode);
    await tester.pump(const Duration(milliseconds: 200));
    repository.pending.single.complete(
      const PlaybackPlan(url: '', session: 'invalid'),
    );
    await tester.pump();
    expect(repository.released, ['invalid']);
    preloader.prepare(drama, episode);
    await tester.pump(const Duration(seconds: 1));
    expect(repository.requested.length, 1);
    now = now.add(const Duration(seconds: 30));
    preloader.prepare(drama, episode);
    await tester.pump(const Duration(milliseconds: 200));
    expect(repository.requested.length, 2);
    preloader.dispose();
    repository.pending.last.complete(plan);
    await tester.pump();
    expect(repository.released, ['invalid', 'next']);
  });
}
