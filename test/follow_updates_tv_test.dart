import 'package:duanju_app/follow_update_checker.dart';
import 'package:duanju_app/follow_updates.dart';
import 'package:duanju_app/follow_updates_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'follow_updates_test.dart' show season;
import 'remote_test_helpers.dart';

void main() {
  testWidgets(
    'TV update cards navigate, opening retains unread, manual acknowledgement clears only that series',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final store = testStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      for (var i = 0; i < 4; i++) {
        final drama = season(10, series: '合成系列$i');
        await store.toggleFavorite(drama);
        await store.saveFollowCheck(
          followSeriesKey(drama),
          [season(11, series: '合成系列$i')],
          complete: true,
          epoch: store.profileEpoch,
        );
      }
      final repository = FixtureRepository();
      final checker = FollowUpdateChecker(repository, store);
      addTearDown(checker.dispose);
      await tester.pumpWidget(
        televisionHost(
          child: FollowUpdatesScreen(
            repository: repository,
            store: store,
            checker: checker,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final grid = tester.widget<RemoteGrid>(find.byType(RemoteGrid));
      expect(grid.columns, 3);
      final first = store.updatedSubscriptions.first;
      focusRemote(tester, find.byKey(ValueKey('follow-update-${first.key}')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        startsWith('remote-'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(store.followUpdateCount, 4);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(store.followUpdateCount, 4);
      await tester.tap(find.byKey(ValueKey('follow-update-${first.key}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部已知晓'));
      await tester.pumpAndSettle();
      expect(store.followUpdateCount, 3);
      expect(store.followSeriesState(first).unread, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
