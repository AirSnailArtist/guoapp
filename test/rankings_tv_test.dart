import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:duanju_app/rankings_screen.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

class RankingFixture extends FixtureRepository {
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'hongguo-hot', source: 'hongguo', name: '总热播榜'),
    RankingBoard(id: 'hongguo-real', source: 'hongguo', name: '真人剧榜'),
  ];

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage(
    items: List.generate(
      30,
      (i) => RankingItem(
        i + 1,
        Drama(
          id: 'synthetic-$i',
          source: 'hongguo',
          title: '合成剧${i + 1}',
          episodes: 20,
        ),
        metric: '${1000 - i}热度',
      ),
    ),
  );
}

void main() {
  testWidgets(
    'TV ranking cards retain visible focus across rows and back to categories',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await tester.pumpWidget(
        televisionHost(
          child: RankingsScreen(
            repository: RankingFixture(),
            store: store,
            initialGroup: 'hongguo',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final grid = tester.widget<RemoteGrid>(find.byType(RemoteGrid));
      expect(grid.columns, 6);
      focusRemote(tester, find.byKey(const ValueKey('category-hongguo-hot')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-synthetic-0',
      );
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-synthetic-13',
      );
      final focused = find.byKey(const ValueKey('rank-14-synthetic-13'));
      expect(focused, findsOneWidget);
      expect(
        tester.getRect(focused).overlaps(const Rect.fromLTWH(0, 0, 960, 540)),
        isTrue,
      );
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot(startsWith('remote-synthetic-')),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
