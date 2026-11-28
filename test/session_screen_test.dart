import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:openmettle_app/api/client.dart';
import 'package:openmettle_app/main.dart';

const _installed = Capability(
  id: 'search.web',
  kind: 'tool',
  installed: true,
  authorization: false,
  readiness: 'ready',
);
const _absent = Capability(
  id: 'media.image',
  kind: 'media',
  installed: false,
  authorization: null,
);
const _unrecognized = Capability(
  id: 'retrieval.an_example_capability_id_with_a_long_unbroken_label',
  kind: 'future_kind',
  installed: true,
  authorization: true,
  readiness: 'future_state',
);

class _FakeSessionClient implements SessionClient {
  Future<bool> Function() session = () async => true;
  Future<SignInResult> Function() login = () async =>
      SignInResult.browserOpened;
  Future<void> Function() logout = () async {};
  Future<List<Capability>> Function() inventory = () async => [_installed];
  final calls = <String>[];

  @override
  Future<bool> checkSession() {
    calls.add('session');
    return session();
  }

  @override
  Future<SignInResult> signIn() {
    calls.add('login');
    return login();
  }

  @override
  Future<void> signOut() {
    calls.add('logout');
    return logout();
  }

  @override
  Future<List<Capability>> capabilities() {
    calls.add('capabilities');
    return inventory();
  }
}

class _NativeClient extends _FakeSessionClient implements SessionUpdates {
  final links = StreamController<void>.broadcast();

  @override
  Stream<void> get sessionUpdates => links.stream;
}

void _visibility(WidgetTester tester, {required bool visible}) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(
    visible ? AppLifecycleState.resumed : AppLifecycleState.hidden,
  );
}

void main() {
  testWidgets('checks on launch and starts sign-in with the keyboard', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final session = Completer<bool>();
    final login = Completer<SignInResult>();
    final client = _FakeSessionClient();
    client.session = () => session.future;
    client.login = () => login.future;

    await tester.pumpWidget(OpenMettleApp(client: client));
    expect(
      tester.getSemantics(find.text('Checking your session…')),
      isSemantics(label: 'Checking your session…', isLiveRegion: true),
    );
    expect(client.calls, ['session']);

    session.complete(false);
    await tester.pumpAndSettle();
    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    expect(
      tester.getSemantics(signIn),
      isSemantics(label: 'Sign in', isButton: true, hasTapAction: true),
    );
    expect(tester.getSize(signIn).height, greaterThanOrEqualTo(48));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(tester.widget<FilledButton>(signIn).focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('Opening sign-in…'), findsOneWidget);
    expect(client.calls, ['session', 'login']);

    login.completeError(StateError('detail from server'));
    await tester.pumpAndSettle();
    final retry = find.widgetWithText(FilledButton, 'Retry sign-in');
    expect(find.text('Could not open sign-in.'), findsOneWidget);
    expect(find.textContaining('detail from server'), findsNothing);
    expect(tester.widget<FilledButton>(retry).focusNode!.hasFocus, isTrue);
    semantics.dispose();
  });

  testWidgets('checks the session when returning from the sign-in handoff', (
    tester,
  ) async {
    final client = _FakeSessionClient();
    client.session = () async => false;
    client.inventory = () async => [];
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Opening sign-in…'), findsOneWidget);

    client.session = () async => true;
    _visibility(tester, visible: false);
    _visibility(tester, visible: true);
    await tester.pumpAndSettle();

    expect(find.text('Signed in'), findsOneWidget);
    expect(find.text('No capabilities were reported.'), findsOneWidget);
    expect(client.calls, ['session', 'login', 'session', 'capabilities']);
  });

  testWidgets('loads a cold session and rechecks resumed and warm links', (
    tester,
  ) async {
    final client = _NativeClient();
    addTearDown(client.links.close);
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    expect(find.text(_installed.id), findsOneWidget);

    client.session = () async => false;
    _visibility(tester, visible: false);
    _visibility(tester, visible: true);
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text(_installed.id), findsNothing);

    // Resume can run before the new intent arrives.
    client.session = () async => true;
    client.links.add(null);
    await tester.pumpAndSettle();
    expect(find.text(_installed.id), findsOneWidget);
    expect(client.calls, [
      'session',
      'capabilities',
      'session',
      'session',
      'capabilities',
    ]);
  });

  testWidgets('loads a session that arrives just before sign-in', (
    tester,
  ) async {
    final client = _NativeClient()..session = () async => false;
    addTearDown(client.links.close);
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    client.login = () async => SignInResult.sessionPresent;
    client.session = () async => true;
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text(_installed.id), findsOneWidget);
  });

  testWidgets('a callback signal during logout does not reopen the session', (
    tester,
  ) async {
    final pending = Completer<void>();
    final client = _NativeClient()..logout = () => pending.future;
    addTearDown(client.links.close);
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    client.links.add(null);
    await tester.pump();
    pending.complete();
    await tester.pumpAndSettle();
    expect(client.calls, ['session', 'capabilities', 'logout']);
    expect(find.text('Signed out'), findsOneWidget);
  });

  testWidgets('offers logout retry after restarting with uncertain logout', (
    tester,
  ) async {
    final client = _NativeClient()
      ..session = () async =>
          throw const ApiFailure(ApiFailureKind.signOutUncertain);
    addTearDown(client.links.close);
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    expect(find.text('Could not confirm sign-out.'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);

    client.links.add(null);
    await tester.pumpAndSettle();
    expect(client.calls, ['session']);
    await tester.tap(find.text('Retry sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(client.calls, ['session', 'logout']);
  });

  testWidgets('recovers when sign-in navigation never leaves the page', (
    tester,
  ) async {
    final client = _FakeSessionClient()..session = () async => false;
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check session'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(client.calls, ['session', 'login', 'session']);
  });

  testWidgets('can sign out after the session check fails', (tester) async {
    final client = _FakeSessionClient();
    client.session = () async => throw StateError('unavailable');
    client.logout = () async => throw SessionExpired();
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    expect(find.text('Could not check your session.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(client.calls, ['session', 'logout']);
  });

  testWidgets('refresh hides private data before retrying a service failure', (
    tester,
  ) async {
    final client = _FakeSessionClient();
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    expect(find.text(_installed.id), findsOneWidget);

    final pendingInventory = Completer<List<Capability>>();
    client.inventory = () => pendingInventory.future;
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Loading capabilities…'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text(_installed.id), findsNothing);

    pendingInventory.completeError(StateError('detail from server'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load capabilities.'), findsOneWidget);
    expect(find.text(_installed.id), findsNothing);
    expect(find.text('Sign in'), findsNothing);
    expect(find.textContaining('detail from server'), findsNothing);

    client.inventory = () async => [];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No capabilities were reported.'), findsOneWidget);
    expect(client.calls, [
      'session',
      'capabilities',
      'session',
      'capabilities',
      'session',
      'capabilities',
    ]);
  });

  testWidgets('signs out while a capabilities request is pending', (
    tester,
  ) async {
    final inventory = Completer<List<Capability>>();
    final client = _FakeSessionClient()..inventory = () => inventory.future;
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Loading capabilities…'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    inventory.complete([_installed]);
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text(_installed.id), findsNothing);
    expect(client.calls, ['session', 'capabilities', 'logout']);
  });

  testWidgets('handles session expiry during the capability request', (
    tester,
  ) async {
    final client = _FakeSessionClient()
      ..inventory = () async => throw SessionExpired();

    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Capabilities'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('clears inventory while sign-out is pending and uncertain', (
    tester,
  ) async {
    final pendingLogout = Completer<void>();
    final client = _FakeSessionClient()..logout = () => pendingLogout.future;
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    expect(find.text(_installed.id), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Signing out…'), findsOneWidget);
    expect(find.text(_installed.id), findsNothing);
    expect(find.text('Signed out'), findsNothing);

    pendingLogout.completeError(StateError('uncertain'));
    await tester.pumpAndSettle();
    expect(find.text('Could not confirm sign-out.'), findsOneWidget);
    expect(find.text(_installed.id), findsNothing);
    expect(find.text('Sign in'), findsNothing);

    _visibility(tester, visible: false);
    _visibility(tester, visible: true);
    await tester.pumpAndSettle();
    expect(client.calls, ['session', 'capabilities', 'logout']);

    client.logout = () async {};
    await tester.tap(find.text('Retry sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text(_installed.id), findsNothing);
    expect(client.calls, ['session', 'capabilities', 'logout', 'logout']);
  });

  testWidgets('ignores window blur and invalidates hidden-tab requests', (
    tester,
  ) async {
    final client = _FakeSessionClient();
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(client.calls, ['session', 'capabilities']);
    expect(find.text(_installed.id), findsOneWidget);

    final stale = Completer<List<Capability>>();
    client.inventory = () => stale.future;
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Loading capabilities…'), findsOneWidget);

    client.inventory = () async => [_absent];
    _visibility(tester, visible: false);
    _visibility(tester, visible: true);
    await tester.pumpAndSettle();
    expect(find.text(_absent.id), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    stale.complete([_installed]);
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text(_absent.id), findsNothing);
    expect(find.text(_installed.id), findsNothing);
  });

  testWidgets('shows independent statuses on a narrow viewport at 200%', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 620));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final client = _FakeSessionClient()
      ..inventory = () async => [_installed, _absent, _unrecognized];
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();

    final heading = tester.element(find.text('OpenMettle'));
    expect(MediaQuery.textScalerOf(heading).scale(14), 28);
    final scroll = find.byType(Scrollable);
    for (final text in [
      'Installation · Installed',
      'Authorization · Denied',
      'Readiness · Ready',
      'Installation · Not installed',
      'Authorization · Unknown',
      'Readiness · Not reported',
      _unrecognized.id,
      'Kind · future_kind',
      'Authorization · Allowed',
      'Readiness · Unrecognized',
    ]) {
      final textWidget = find.text(text);
      await tester.scrollUntilVisible(textWidget, 100, scrollable: scroll);
      await tester.pumpAndSettle();
      final viewport = tester.getRect(scroll);
      final label = tester.getRect(textWidget);
      expect(
        viewport.contains(label.center),
        isTrue,
        reason: '$text at $label with viewport $viewport',
      );
      expect(label.left, greaterThanOrEqualTo(viewport.left));
      expect(label.right, lessThanOrEqualTo(viewport.right));
    }
    expect(tester.takeException(), isNull);
  });
}
