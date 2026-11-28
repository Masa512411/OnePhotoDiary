import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/main.dart';
import 'package:one_photo_diary/providers/auth_provider.dart';
import 'package:one_photo_diary/providers/calendar_provider.dart';
import 'package:one_photo_diary/providers/photo_provider.dart';
import 'package:one_photo_diary/providers/reminder_provider.dart';
import 'package:one_photo_diary/screens/app_lock_gate.dart';
import 'package:one_photo_diary/screens/camera_screen.dart';
import 'package:one_photo_diary/screens/selection_screen.dart';
import 'package:one_photo_diary/services/notification_service.dart';

import 'helpers/fake_local_auth.dart';
import 'helpers/fake_notifications.dart';

/// ストレージに触れず、読み込み直しの回数を記録するPhotoNotifier
class FakePhotoNotifier extends PhotoNotifier {
  int reloadCalls = 0;

  @override
  List<File> build() => [];

  @override
  Future<void> reload() async => reloadCalls++;
}

void main() {
  late FakeLocalAuthentication auth;
  late FakeNotificationsPlugin plugin;
  late NotificationService notifications;
  late FakePhotoNotifier photos;
  late ProviderContainer container;
  late DateTime now;

  final todayKey = DateTime.now().toIso8601String().substring(0, 10);
  final lockScreen = find.text('もう一度認証する');
  final camera = find.byType(CameraScreen);

  Future<void> initNotifications() async {
    notifications = NotificationService(
      plugin: plugin,
      localTimezone: () async => 'Asia/Tokyo',
    );
    await notifications.init();
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    plugin = FakeNotificationsPlugin();
    await initNotifications();
  });

  Future<void> pumpApp(WidgetTester tester, {bool authResult = true}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    auth = FakeLocalAuthentication(authResult: authResult);
    photos = FakePhotoNotifier();
    now = DateTime(2026, 1, 1, 12);
    container = ProviderContainer(
      overrides: [
        localAuthProvider.overrideWithValue(auth),
        relockTimerProvider.overrideWithValue(RelockTimer(now: () => now)),
        notificationServiceProvider.overrideWithValue(notifications),
        pendingPhotosProvider.overrideWith(() => photos),
      ],
    );
    addTearDown(container.dispose);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(body: Text('詳細画面')),
                  ),
                ),
                child: const Text('ホーム'),
              ),
            ),
          ),
          builder: (context, child) => AppLockGate(
            navigatorKey: navigatorKey,
            child: ReminderTapHandler(
              navigatorKey: navigatorKey,
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> unlock(WidgetTester tester) async {
    auth.authResult = true;
    await tester.tap(lockScreen);
    await tester.pumpAndSettle();
    expect(lockScreen, findsNothing);
  }

  void goBackground(WidgetTester tester) {
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  Future<void> resume(WidgetTester tester) async {
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('起動中にリマインダーをタップすると撮影画面を開く', (tester) async {
    await pumpApp(tester);

    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();

    expect(camera, findsOneWidget);
    expect(notifications.reminderTapPending.value, isFalse);

    // 閉じたらホームの撮影ボタンと同じく撮影済み写真を読み込み直す
    Navigator.of(tester.element(camera)).pop();
    await tester.pumpAndSettle();
    expect(photos.reloadCalls, 1);
  });

  testWidgets('リマインダー以外の通知のタップでは遷移しない', (tester) async {
    await pumpApp(tester);

    plugin.tap('other');
    await tester.pumpAndSettle();

    expect(camera, findsNothing);
  });

  testWidgets('通知で起動した場合はロック解除後に撮影画面を開く', (tester) async {
    // 起動時のタップ（getNotificationAppLaunchDetails）は初期化時に保留される
    plugin.launchDetails = const NotificationAppLaunchDetails(
      true,
      notificationResponse: NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: 'reminder:21:0',
      ),
    );
    await initNotifications();
    await pumpApp(tester, authResult: false);

    expect(lockScreen, findsOneWidget);
    expect(camera, findsNothing);

    await unlock(tester);

    expect(camera, findsOneWidget);
  });

  testWidgets('ロック中のタップはロック解除まで遷移しない', (tester) async {
    await pumpApp(tester);
    auth.authResult = false;
    container.read(authProvider.notifier).lock();
    await tester.pumpAndSettle();

    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();
    expect(camera, findsNothing);
    expect(notifications.reminderTapPending.value, isTrue);

    await unlock(tester);

    expect(camera, findsOneWidget);
  });

  testWidgets('復帰前に届いたタップは、復帰時に再ロックされたらロック解除まで遷移しない', (tester) async {
    await pumpApp(tester);

    // Androidは通知のタップが復帰（再ロック判定）より先に届くことがある
    goBackground(tester);
    now = now.add(const Duration(seconds: 61));
    plugin.tap('reminder:21:0');
    auth.authResult = false;
    // resumed より前の inactive でもフレームは描画されるが、再ロック判定はまだ行われていない
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(camera, findsNothing);
    await resume(tester);

    expect(lockScreen, findsOneWidget);
    expect(camera, findsNothing);

    await unlock(tester);

    expect(camera, findsOneWidget);
  });

  testWidgets('復帰前に届いたタップは、再ロックされなければ復帰後に開く', (tester) async {
    await pumpApp(tester);

    goBackground(tester);
    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();
    expect(camera, findsNothing);

    await resume(tester);

    expect(camera, findsOneWidget);
  });

  testWidgets('連続でタップしても撮影画面は1つだけ開く', (tester) async {
    await pumpApp(tester);

    plugin.tap('reminder:21:0');
    await tester.pump();
    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();
    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();

    expect(camera, findsOneWidget);
    expect(notifications.reminderTapPending.value, isFalse);
  });

  testWidgets('撮影フロー以外の画面を開いていても撮影画面を開く', (tester) async {
    await pumpApp(tester);
    // 設定画面でリマインダーを設定してそのまま離脱した場合など
    await tester.tap(find.text('ホーム'));
    await tester.pumpAndSettle();

    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();

    expect(camera, findsOneWidget);
  });

  testWidgets('撮影画面を開いている間は重ねて開かない', (tester) async {
    await pumpApp(tester);
    // ホームの撮影ボタンから開いた場合と同じ状態
    Navigator.of(
      tester.element(find.text('ホーム')),
    ).push(MaterialPageRoute(builder: (_) => const CameraScreen()));
    await tester.pumpAndSettle();

    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();

    expect(camera, findsOneWidget);
    // 後で撮影画面を閉じたときに突然開かないよう、タップは破棄する
    expect(notifications.reminderTapPending.value, isFalse);
  });

  testWidgets('選択・編集の画面が下に残っている間も重ねて開かない', (tester) async {
    await pumpApp(tester);
    final navigator = Navigator.of(tester.element(find.text('ホーム')));
    navigator.push(
      MaterialPageRoute(builder: (_) => const SelectionScreen(photos: [])),
    );
    await tester.pumpAndSettle();
    navigator.push(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('詳細画面'))),
    );
    await tester.pumpAndSettle();

    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();

    expect(find.text('詳細画面'), findsOneWidget);
    expect(camera, findsNothing);
  });

  testWidgets('今日が記録済みなら撮影画面へは進まず、ホームで今日を選択する', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'diary_dates': jsonEncode([todayKey]),
      'diary_$todayKey': jsonEncode({
        'photo': 'a.jpg',
        'caption': '今日の一言',
        'date': todayKey,
      }),
    });
    await pumpApp(tester);
    // 別の日を選んでいた場合も今日に戻す
    container
        .read(calendarProvider.notifier)
        .selectDay(DateTime(2020, 1, 1), DateTime(2020, 1, 1));

    plugin.tap('reminder:21:0');
    await tester.pumpAndSettle();

    expect(camera, findsNothing);
    expect(notifications.reminderTapPending.value, isFalse);
    final selected = container.read(calendarProvider).selectedDay!;
    expect(selected.toIso8601String().substring(0, 10), todayKey);
  });
}
