import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/account_deletion.dart';
import 'package:motorcycle_parking/domain/account_deletion_display.dart';

import 'account_deletion_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 11, 1, 3);

  group('登入時間與冷靜期判斷', () {
    test('從 JWT amr 讀最近一次登入，略過匿名與壞掉的 token', () {
      final at = DateTime.utc(2026, 11, 1, 2, 55);
      expect(signedInAtFromJwt(jwtSignedInAt(at)), at);
      expect(signedInAtFromJwt(null), isNull);
      expect(signedInAtFromJwt('not-a-jwt'), isNull);
      expect(signedInAtFromJwt('a.b.c'), isNull);
    });

    test('超過 9 分鐘或不知道登入時間就要再登入', () {
      expect(
        needsRecentSignIn(now.subtract(const Duration(minutes: 8)), now),
        isFalse,
      );
      expect(
        needsRecentSignIn(now.subtract(const Duration(minutes: 9)), now),
        isFalse,
      );
      expect(
        needsRecentSignIn(
          now.subtract(const Duration(minutes: 9, seconds: 1)),
          now,
        ),
        isTrue,
      );
      expect(needsRecentSignIn(null, now), isTrue);
    });

    test('登入晚於申請才算冷靜期內的新登入；不知道時當成新登入', () {
      final requested = DateTime.parse(pendingRequestedAt);
      expect(
        signedInAfterRequest(
          requested.add(const Duration(minutes: 1)),
          pendingRequestedAt,
        ),
        isTrue,
      );
      expect(
        signedInAfterRequest(
          requested.subtract(const Duration(minutes: 1)),
          pendingRequestedAt,
        ),
        isFalse,
      );
      expect(signedInAfterRequest(null, pendingRequestedAt), isTrue);
    });

    test('刪除日期用台灣日期顯示', () {
      // 16:00 UTC is already the next day in Taiwan.
      expect(deletionDateLabel('2026-11-07T16:30:00Z'), '11 月 8 日');
      expect(deletionDateLabel('2026-11-08T02:00:00+00:00'), '11 月 8 日');
      expect(deletionDateLabel(null), '7 天');
      expect(scheduledLine(pendingScheduledAt), '帳號預計於 11 月 8 日後刪除。');
    });

    test('Email 遮罩與帳號說明', () {
      expect(maskEmail('abc@gmail.com'), 'a••••@gmail.com');
      expect(
        reauthAccountLine(email: 'abc@gmail.com', apple: false),
        'a••••@gmail.com・Google',
      );
      expect(
        reauthAccountLine(email: 'x@privaterelay.appleid.com', apple: true),
        'Apple ID・隱藏的電子郵件',
      );
    });
  });

  group('錯誤碼對應', () {
    test('後端錯誤碼與網路錯誤', () {
      expect(
        deletionFailure(apiError('auth.sign_in_required')),
        isA<SignInRequired>(),
      );
      expect(
        deletionFailure(apiError('auth.recent_sign_in_required')),
        isA<ReauthRequired>(),
      );
      expect(
        deletionFailure(apiError('account.admin_cannot_self_delete', 'PT403')),
        isA<AdminCannotDelete>(),
      );
      expect(
        deletionFailure(apiError('account.deletion_in_progress', 'PT409')),
        isA<DeletionInProgress>(),
      );
      expect(
        deletionFailure(apiError('request.invalid', 'PT400')),
        isA<DeletionUnexpected>(),
      );
      expect(
        deletionFailure(const SocketException('offline')),
        isA<DeletionNetworkError>(),
      );
    });
  });

  group('DeletionAttempt 順序', () {
    test('Google 剛登入：不再登入，直接申請', () async {
      final gateway = FakeDeletionGateway(
        current: google(signedInAt: now.subtract(const Duration(minutes: 2))),
      );
      final attempt = DeletionAttempt(gateway, clock: () => now);
      expect(attempt.needsReauth, isFalse);
      await attempt.submit();
      expect(gateway.calls, ['request']);
    });

    test('Google 超過 9 分鐘：先再登入同一個帳號再申請', () async {
      final gateway = FakeDeletionGateway(
        current: google(signedInAt: now.subtract(const Duration(minutes: 30))),
      )..reauths.add(google(signedInAt: now));
      final attempt = DeletionAttempt(gateway, clock: () => now);
      expect(attempt.needsReauth, isTrue);
      await expectLater(attempt.submit(), throwsA(isA<ReauthRequired>()));
      await attempt.reauthenticate();
      expect(attempt.needsReauth, isFalse);
      await attempt.submit();
      expect(gateway.calls, ['reauth:google', 'request']);
    });

    test('Apple 即使剛登入也要再登入，先 apple-revoke 再申請', () async {
      final gateway = FakeDeletionGateway(current: apple(signedInAt: now))
        ..reauths.add(apple(signedInAt: now, token: 'fresh-rt'));
      final attempt = DeletionAttempt(gateway, clock: () => now);
      expect(attempt.needsReauth, isTrue);
      await attempt.reauthenticate();
      await attempt.submit();
      expect(gateway.calls, [
        'reauth:apple',
        'revoke:fresh-rt:refresh_token',
        'request',
      ]);
      expect(attempt.appleRevokeFailed, isFalse);
    });

    test('apple-revoke 失敗不擋申請，並記下撤銷失敗', () async {
      final gateway = FakeDeletionGateway(current: apple(signedInAt: now))
        ..revokes.add(Exception('apple.revoke_failed'));
      final attempt = DeletionAttempt(gateway, clock: () => now);
      await attempt.reauthenticate();
      await attempt.submit();
      expect(gateway.calls.last, 'request');
      expect(attempt.appleRevokeFailed, isTrue);
    });

    test('apple-revoke 回管理員時停止，不申請', () async {
      final gateway = FakeDeletionGateway(current: apple(signedInAt: now))
        ..revokes.add(const AdminCannotDelete());
      final attempt = DeletionAttempt(gateway, clock: () => now);
      await attempt.reauthenticate();
      await expectLater(attempt.submit(), throwsA(isA<AdminCannotDelete>()));
      expect(gateway.calls.contains('request'), isFalse);
    });

    test('撤銷成功但申請失敗：重試只再申請，不再撤銷', () async {
      final gateway = FakeDeletionGateway(current: apple(signedInAt: now))
        ..requests.add(const SocketException('offline'));
      final attempt = DeletionAttempt(gateway, clock: () => now);
      await attempt.reauthenticate();
      await expectLater(attempt.submit(), throwsA(isA<DeletionNetworkError>()));
      expect(attempt.needsReauth, isFalse);
      await attempt.submit();
      expect(gateway.calls, [
        'reauth:apple',
        'revoke:apple-rt:refresh_token',
        'request',
        'request',
      ]);
    });

    test('登入成別的帳號：還原原帳號並中止', () async {
      final gateway = FakeDeletionGateway(current: google(signedInAt: null))
        ..reauths.add(google(signedInAt: now, id: 'other'));
      final attempt = DeletionAttempt(gateway, clock: () => now);
      await expectLater(
        attempt.reauthenticate(),
        throwsA(
          isA<WrongAccount>().having(
            (e) => e.email,
            'email',
            'other@gmail.com',
          ),
        ),
      );
      expect(gateway.calls, ['reauth:google', 'restore']);
      expect(gateway.current?.id, 'rider');
    });

    test('後端回 recent_sign_in_required 時要求再登入', () async {
      final gateway = FakeDeletionGateway(current: google(signedInAt: now))
        ..requests.add(apiError('auth.recent_sign_in_required'));
      final attempt = DeletionAttempt(gateway, clock: () => now);
      await expectLater(attempt.submit(), throwsA(isA<ReauthRequired>()));
      expect(attempt.needsReauth, isTrue);
      await attempt.reauthenticate();
      await attempt.submit();
      expect(gateway.calls, ['request', 'reauth:google', 'request']);
    });
  });

  group('AccountDeletionController', () {
    test('舊 session（登入早於申請）：本機登出並顯示登出後提示', () async {
      final gateway = FakeDeletionGateway(
        current: google(signedInAt: DateTime.utc(2026, 10, 30)),
      )..statuses.add(pendingState());
      final controller = AccountDeletionController(gateway, clock: () => now);
      await controller.check();
      expect(gateway.calls, ['status', 'signOut']);
      expect(controller.pending, isNull);
      expect(controller.notice?.scheduledAt, pendingScheduledAt);
    });

    test('冷靜期內新登入：顯示確認頁', () async {
      final gateway = FakeDeletionGateway(current: google(signedInAt: now))
        ..statuses.add(pendingState());
      final controller = AccountDeletionController(gateway, clock: () => now);
      await controller.check();
      expect(controller.pending?.status, 'pending');
      expect(gateway.calls, ['status']);
    });

    test('刪除流程進行中不讀 status', () async {
      final gateway = FakeDeletionGateway(current: google(signedInAt: now))
        ..statuses.add(pendingState());
      final controller = AccountDeletionController(gateway, clock: () => now);
      await controller.guard(controller.check);
      expect(gateway.calls, isEmpty);
    });

    test('申請成功：登出、清停車紀錄、顯示提示', () async {
      var cleared = false;
      final gateway = FakeDeletionGateway(current: google(signedInAt: now));
      final controller = AccountDeletionController(
        gateway,
        clearLocalData: () async => cleared = true,
      );
      await controller.completeRequest(pendingState(), appleRevokeFailed: true);
      expect(gateway.calls, ['signOut']);
      expect(cleared, isTrue);
      expect(controller.notice?.appleRevokeFailed, isTrue);
    });

    test('取消刪除、繼續刪除（Apple 再撤銷一次）與 409', () async {
      final gateway = FakeDeletionGateway(current: apple(signedInAt: now))
        ..statuses.add(pendingState());
      final controller = AccountDeletionController(gateway, clock: () => now);
      await controller.check();
      await controller.cancelPending();
      expect(controller.pending, isNull);
      expect(controller.banner?.continued, isFalse);

      gateway.statuses.add(pendingState());
      await controller.check();
      await controller.continuePending();
      expect(gateway.calls.sublist(gateway.calls.length - 2), [
        'revoke:apple-rt:refresh_token',
        'signOut',
      ]);
      expect(controller.banner?.continued, isTrue);
      expect(controller.pending, isNull);

      gateway
        ..current = apple(signedInAt: now)
        ..statuses.add(pendingState())
        ..cancels.add(apiError('account.deletion_in_progress', 'PT409'));
      await controller.check();
      await expectLater(
        controller.cancelPending(),
        throwsA(isA<DeletionInProgress>()),
      );
      await controller.acknowledgeInProgress();
      expect(gateway.calls.last, 'signOut');
      expect(controller.pending, isNull);
    });
  });
}
