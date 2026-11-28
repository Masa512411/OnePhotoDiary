import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// ローカル通知の初期化・スケジュールを担うサービス
///
/// 「記録済みの日はスキップする」ため、毎日繰り返す通知
/// （matchDateTimeComponents: DateTimeComponents.time）は使わず、
/// 日付ごとの単発通知を [scheduleDays] 日分まとめて予約する。
/// 繰り返し通知は個別の日だけ止められず、iOS では開始日も無視されて
/// 次の該当時刻から鳴るため、当日の記録済みスキップができない。
/// 予約が切れないよう、起動時・復帰時・記録時に再スケジュールする。
///
/// 再スケジュールは全取り消しせず差分で反映する（cancelAll は表示中の通知まで消すため）。
/// 通知 ID は日付ごとに固定（YYYYMMDD）し、同じ ID の再予約は上書きになる。
class NotificationService {
  /// [plugin]・[clock]・[localTimezone]・[trustPendingList] はテストで差し替えるための引数
  @visibleForTesting
  NotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    tz.TZDateTime Function()? clock,
    Future<String> Function()? localTimezone,
    bool? trustPendingList,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _clock = clock ?? (() => tz.TZDateTime.now(tz.local)),
       _localTimezone = localTimezone ?? FlutterTimezone.getLocalTimezone,
       _trustPendingList =
           trustPendingList ?? defaultTargetPlatform != TargetPlatform.android;

  static final NotificationService instance = NotificationService();

  static const _channelId = 'daily_reminder';
  static const _channelName = '毎日のリマインダー';
  static const _channelDescription = '今日の一枚を記録するリマインドです';

  /// 事前スケジュールする日数（起動時・復帰時に再スケジュールされる前提）
  /// iOS の予約できるローカル通知は1アプリ64件までで、このアプリは他に通知を予約しないため、
  /// 上限内でしばらくアプリを開かなくても届くよう60日分にする
  static const int scheduleDays = 60;

  /// 日付ごとの固定IDに切り替える前の旧ID（0〜13）。残っていれば取り消す
  static const int _legacyIdCount = 14;

  final FlutterLocalNotificationsPlugin _plugin;
  final tz.TZDateTime Function() _clock;
  final Future<String> Function() _localTimezone;

  /// 予約一覧（pendingNotificationRequests）が実際の予約と一致するか。
  /// iOS は OS の予約一覧そのものだが、Android はプラグインが SharedPreferences に
  /// 保存したキャッシュで、強制停止やバックアップ復元で AlarmManager の予約が消えても残る
  final bool _trustPendingList;
  bool _initialized = false;

  /// リマインダー通知がタップされ、まだ撮影画面へ進んでいないか。
  /// 起動時（ProviderContainer の生成前）のタップも取りこぼさないようサービス側で保持し、
  /// 画面側が遷移できる状態になってから [consumeReminderTap] で取り出す。
  /// 連続タップや、起動理由とコールバックの両方で届いた場合も1回にまとまる
  final ValueNotifier<bool> reminderTapPending = ValueNotifier(false);

  Future<void> init() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    final localName = await _localTimezone();
    tz.setLocalLocation(tz.getLocation(localName));

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: handleNotificationResponse,
    );

    // アプリが終了している状態から通知のタップで起動された場合
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch != null && launch.didNotificationLaunchApp) {
        handleNotificationResponse(launch.notificationResponse);
      }
    } catch (e) {
      debugPrint('通知による起動の確認に失敗しました: $e');
    }

    _initialized = true;
  }

  /// リマインダー通知のタップか（このサービスが予約した通知だけを対象にする）
  @visibleForTesting
  static bool isReminderTap(NotificationResponse? response) =>
      response != null &&
      response.notificationResponseType ==
          NotificationResponseType.selectedNotification &&
      (response.payload?.startsWith(_reminderPayloadPrefix) ?? false);

  /// 通知がタップされたときに呼ばれる。リマインダーなら遷移待ちにする
  @visibleForTesting
  void handleNotificationResponse(NotificationResponse? response) {
    if (isReminderTap(response)) reminderTapPending.value = true;
  }

  /// 遷移待ちのタップを取り出す（取り出したらtrue）
  bool consumeReminderTap() {
    if (!reminderTapPending.value) return false;
    reminderTapPending.value = false;
    return true;
  }

  /// 端末のタイムゾーンを読み直す（バックグラウンド中に変更された場合に備える）
  /// 取得できない・未知のタイムゾーンの場合は現在の設定のまま使う
  Future<void> refreshTimeZone() async {
    try {
      final localName = await _localTimezone();
      if (localName == tz.local.name) return;
      tz.setLocalLocation(tz.getLocation(localName));
    } catch (e) {
      debugPrint('タイムゾーンの再取得に失敗しました: $e');
    }
  }

  /// 通知許可をリクエスト（iOS は明示的、Android 13+ は POST_NOTIFICATIONS）
  Future<bool> requestPermissions() async {
    final iosImpl = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final iosGranted = await iosImpl?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final androidGranted = await androidImpl?.requestNotificationsPermission();

    return (iosGranted ?? true) && (androidGranted ?? true);
  }

  /// すべての予約通知をキャンセル（表示中の通知も消える。リマインダーを無効にするときだけ使う）
  Future<void> cancelAll() => _plugin.cancelAll();

  /// 日付ごとの通知ID（YYYYMMDD）
  @visibleForTesting
  static int idForDate(DateTime date) =>
      date.year * 10000 + date.month * 100 + date.day;

  /// このサービスが予約した通知のIDか（日付ID または 旧ID）
  static bool _isReminderId(int id) {
    if (id >= 0 && id < _legacyIdCount) return true;
    final year = id ~/ 10000, month = id ~/ 100 % 100, day = id % 100;
    return year >= 2000 && month >= 1 && month <= 12 && day >= 1 && day <= 31;
  }

  /// 予約時刻をpayloadに持たせ、時刻が変わっていない予約は入れ直さない
  static String _payloadFor(TimeOfDay time) =>
      '$_reminderPayloadPrefix${time.hour}:${time.minute}';

  static const _reminderPayloadPrefix = 'reminder:';

  /// 指定された時刻で今後 [scheduleDays] 日分の通知を予約する。
  /// [skipDates] に含まれる日（YYYY-MM-DD 形式）はスキップ。
  ///
  /// 予約済みの通知との差分だけを反映する。
  /// - 不要になった予約（記録済み・期間外・時刻変更で過ぎた日）だけを取り消す
  /// - 未予約または時刻が変わった日だけを予約する（同じIDで上書き）。
  ///   Android は予約一覧が当てにならないため、予約すべき日を毎回すべて予約し直す
  ///   （予約すべき日は未来の時刻だけなので、表示中の通知には影響しない）
  /// - 表示済みの通知は予約一覧に無いため触らない。ただし今日を記録したら今日の分は消す
  Future<void> scheduleDailyReminder({
    required TimeOfDay time,
    required Set<String> skipDates,
  }) async {
    final payload = _payloadFor(time);

    const notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    final now = _clock();
    final todayId = idForDate(now);
    final todayRecorded = skipDates.contains(
      now.toIso8601String().substring(0, 10),
    );

    // 予約すべき日付ID → 予約日時
    final wanted = <int, tz.TZDateTime>{};
    for (var offset = 0; offset < scheduleDays; offset++) {
      // Duration で足すと夏時間の切り替わりで時刻がずれるため日付で組み立てる
      final target = tz.TZDateTime(
        now.location,
        now.year,
        now.month,
        now.day + offset,
        time.hour,
        time.minute,
      );

      if (target.isBefore(now)) continue;

      final dateKey = target.toIso8601String().substring(0, 10);
      if (skipDates.contains(dateKey)) continue;

      wanted[idForDate(target)] = target;
    }

    final pending = {
      for (final request in await _plugin.pendingNotificationRequests())
        request.id: request.payload,
    };

    for (final MapEntry(key: id, value: pendingPayload) in pending.entries) {
      if (wanted.containsKey(id) || !_isReminderId(id)) continue;
      // Android の inexact 予約は時刻を少し過ぎてから届くことがあるため、
      // 未記録の今日の分は時刻が変わっていなければ残す
      if (id == todayId && !todayRecorded && pendingPayload == payload) {
        continue;
      }
      await _plugin.cancel(id);
    }

    // 今日を記録したら、表示中の今日のリマインダーも消す
    if (todayRecorded && !pending.containsKey(todayId)) {
      await _plugin.cancel(todayId);
    }

    for (final MapEntry(key: id, value: target) in wanted.entries) {
      if (_trustPendingList && pending[id] == payload) continue;
      await _plugin.zonedSchedule(
        id,
        '今日の一枚を記録しましょう',
        'カメラを開いて、今日の一瞬を残そう',
        target,
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
    }
  }
}
