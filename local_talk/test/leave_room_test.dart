import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_talk/controllers/intercom_controller.dart';
import 'package:local_talk/screens/host_ready_screen.dart';
import 'package:local_talk/screens/intercom_screen.dart';
import 'package:provider/provider.dart';

/// Regression tests for the two navigation bugs found on two real devices.
void main() {
  group('leaving a room', () {
    test('resets every field that would block a second attempt', () async {
      // The reported symptom was "leave sometimes works, sometimes it does
      // not". The durable part of that bug is state left behind: if any of
      // these survive a leave, the *next* host/join attempt silently no-ops
      // (`joinRoom` early-returns on `_isConnecting`, and `HostScreen` reads
      // `_setupStage` to decide the room came up).
      final controller = IntercomController();

      await controller.leaveRoom();

      expect(controller.isInRoom, isFalse, reason: 'role must be reset');
      expect(controller.isConnecting, isFalse,
          reason: 'a stuck _isConnecting makes joinRoom a no-op forever');
      expect(controller.setupStage, RoomSetupStage.none,
          reason: 'a stale ready stage makes the next Create a room look OK');
      expect(controller.invite, isNull,
          reason: 'a stale invite would put an old QR in front of guests');
      expect(controller.users, isEmpty);
      expect(controller.roomInfo, isNull);
      expect(controller.currentChannelId, isNull);
      expect(controller.incomingCall, isNull);
      expect(controller.error, isNull,
          reason: 'a leftover error resurfaces on the home screen');
    });

    test('is safe to call twice in a row (double-tapped Leave)', () async {
      // Leave is reachable from the app bar and the back button, and both funnel
      // into the same teardown. The second call must be a no-op rather than
      // racing the first one into a half-torn-down controller.
      final controller = IntercomController();

      await controller.leaveRoom();
      await controller.leaveRoom();

      expect(controller.isInRoom, isFalse);
      expect(controller.setupStage, RoomSetupStage.none);
    });

    test('does not throw when called on a controller that never started', () {
      // Teardown runs on a controller whose audio/plugins were never created.
      // Any unguarded await here is what made Leave unreliable in the field.
      final controller = IntercomController();

      expect(controller.leaveRoom, returnsNormally);
    });
  });

  group('host ready screen', () {
    testWidgets(
        '"Enter the room" opens the intercom instead of the home '
        'screen', (tester) async {
      // The bug: the button called Navigator.pop(). HostScreen had already
      // been pushReplacement'd away by the room creation, so the route beneath
      // was HomeScreen — tapping "Enter the room" threw the host out of their
      // own room.
      final controller = IntercomController();
      await controller.leaveRoom();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: HostReadyScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // The button exists and the QR panel is on screen.
      expect(find.text('Enter the room'), findsOneWidget);
      expect(find.text('Waiting for guests\u2026'), findsOneWidget);

      await tester.tap(find.text('Enter the room'));
      await tester.pumpAndSettle();

      // We must be in the intercom, not back on a home screen.
      expect(find.byType(IntercomScreen), findsOneWidget);
      expect(find.text('LocalTalk'), findsNothing,
          reason: 'the home screen must not be what we land on');
    });
  });
}
