import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:openmettle_app/api/client.dart';
import 'package:openmettle_app/conversations/history.dart';
import 'package:openmettle_app/main.dart';

const _first = '00000000-0000-4000-8000-000000000001';
const _second = '00000000-0000-4000-8000-000000000002';
const _branch = '00000000-0000-4000-8000-000000000003';
const _otherBranch = '00000000-0000-4000-8000-000000000004';
const _time = '2026-11-25T19:30:00Z';
const _conversation = ConversationSummary(id: _first, createdAt: _time);
const _anotherConversation = ConversationSummary(id: _second, createdAt: _time);
const _branchSummary = BranchSummary(
  id: _branch,
  createdAt: _time,
  parentBranchId: null,
  historyAvailable: true,
);
const _otherBranchSummary = BranchSummary(
  id: _otherBranch,
  createdAt: _time,
  parentBranchId: _branch,
  historyAvailable: false,
);
const _latest = HistoryMessage(
  id: 'latest',
  role: 'assistant',
  stopReason: 'limit',
  parts: [
    HistoryPart(kind: 'text', text: 'Latest <b>plain</b> response'),
    HistoryPart(kind: 'attachment', state: 'active'),
    HistoryPart(kind: 'attachment', state: 'retained'),
  ],
);
const _earlier = HistoryMessage(
  id: 'earlier',
  role: 'user',
  parts: [HistoryPart(kind: 'text', text: 'Earlier request')],
);
const _oldest = HistoryMessage(
  id: 'oldest',
  role: 'user',
  parts: [HistoryPart(kind: 'text', text: 'Oldest request')],
);

class _Session implements SessionClient {
  Future<bool> Function() session = () async => true;
  Future<void> Function() logout = () async {};

  @override
  Future<bool> checkSession() => session();

  @override
  Future<List<Capability>> capabilities() async => const [];

  @override
  Future<SignInResult> signIn() async => SignInResult.browserOpened;

  @override
  Future<void> signOut() => logout();
}

class _HistorySession extends _Session implements ConversationSource {
  Future<HistoryPage<ConversationSummary>> Function(String?) readConversations =
      (_) async => const HistoryPage([_conversation]);
  Future<HistoryPage<BranchSummary>> Function(String, String?) readBranches = (
    _,
    _,
  ) async => const HistoryPage([_branchSummary]);
  Future<HistoryPage<HistoryMessage>> Function(String, String, String?)
  readMessages = (_, _, _) async => const HistoryPage([_latest]);
  final calls = <Object?>[];

  @override
  Future<HistoryPage<ConversationSummary>> conversations({String? cursor}) {
    calls.add(('conversations', cursor));
    return readConversations(cursor);
  }

  @override
  Future<HistoryPage<BranchSummary>> branches(
    String conversationId, {
    String? cursor,
  }) {
    calls.add(('branches', conversationId, cursor));
    return readBranches(conversationId, cursor);
  }

  @override
  Future<HistoryPage<HistoryMessage>> messages(
    String conversationId,
    String branchId, {
    String? cursor,
  }) {
    calls.add(('messages', conversationId, branchId, cursor));
    return readMessages(conversationId, branchId, cursor);
  }
}

Future<void> _tap(WidgetTester tester, String label) async {
  final control = find.text(label);
  if (control.evaluate().isEmpty) {
    await tester.scrollUntilVisible(control, 240);
  }
  await Scrollable.ensureVisible(tester.element(control), alignment: 0.5);
  await tester.pump();
  await tester.tap(control);
  await tester.pumpAndSettle();
}

Future<void> _openBranches(WidgetTester tester, _HistorySession client) async {
  await tester.pumpWidget(OpenMettleApp(client: client));
  await tester.pumpAndSettle();
  await _tap(tester, 'Conversations');
  await _tap(tester, 'Conversation $_first');
}

Future<void> _escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

/// Whether keyboard focus is inside [target].
bool _focusedIn(WidgetTester tester, Finder target) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final element = tester.element(target);
  var found = focused == element;
  focused.visitAncestorElements((ancestor) => !(found = ancestor == element));
  return found;
}

Finder _row(String id) => find.byKey(ValueKey(id));

BranchSummary _branchNamed(String id) => BranchSummary(
  id: id,
  createdAt: _time,
  parentBranchId: null,
  historyAvailable: true,
);

/// Opens [target] from the second branch page and returns to the transcript.
Future<void> _openSecondPageBranch(
  WidgetTester tester,
  _HistorySession client, {
  List<BranchSummary> firstPage = const [_branchSummary],
  BranchSummary target = _otherBranchSummary,
}) async {
  client.readBranches = (_, cursor) async => cursor == null
      ? HistoryPage(firstPage, nextCursor: 'branches/2')
      : HistoryPage([target]);
  await _openBranches(tester, client);
  await _tap(tester, 'Load more branches');
  await _tap(tester, 'Branch ${target.id}');
  expect(find.text('Transcript'), findsOneWidget);
  client.calls.clear();
}

void main() {
  testWidgets('history opens only with a signed-in conversation source', (
    tester,
  ) async {
    await tester.pumpWidget(OpenMettleApp(client: _Session()));
    await tester.pumpAndSettle();
    expect(find.text('Conversations'), findsNothing);
    final client = _HistorySession()..session = () async => false;
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Conversations'), findsNothing);
    expect(client.calls, isEmpty);
  });

  testWidgets('lists and explicitly selects, pages plain text and goes back', (
    tester,
  ) async {
    final client = _HistorySession();
    client.readConversations = (cursor) async => cursor == null
        ? const HistoryPage([_conversation], nextCursor: 'conversation/+')
        : const HistoryPage([_conversation, _anotherConversation]);
    client.readBranches = (_, cursor) async => cursor == null
        ? const HistoryPage([_branchSummary], nextCursor: 'branches/+')
        : const HistoryPage([_otherBranchSummary]);
    client.readMessages = (_, _, cursor) async => cursor == null
        ? const HistoryPage([_latest, _earlier], nextCursor: 'older/+')
        : const HistoryPage([_earlier, _oldest]);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();

    final open = find.widgetWithText(OutlinedButton, 'Conversations');
    tester.widget<OutlinedButton>(open).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Personal conversations'), findsOneWidget);
    await _tap(tester, 'Load more conversations');
    expect(find.text('Conversation $_first'), findsOneWidget);
    final choose = find.widgetWithText(TextButton, 'Conversation $_second');
    expect(
      tester.getSemantics(choose),
      isSemantics(
        label: 'Conversation $_second',
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    await _tap(tester, 'Conversation $_second');
    expect(find.text('Branches'), findsOneWidget);
    expect(client.calls, [
      ('conversations', null),
      ('conversations', 'conversation/+'),
      ('branches', _second, null),
    ]);

    await _tap(tester, 'Load more branches');
    expect(find.text('Branch $_otherBranch'), findsOneWidget);
    await _tap(tester, 'Branch $_branch');
    expect(find.text('Transcript'), findsOneWidget);
    expect(find.byType(SelectionArea), findsNWidgets(2));
    expect(find.text('User'), findsOneWidget);
    expect(find.text('Assistant'), findsOneWidget);
    expect(find.text('Attachment available'), findsOneWidget);
    expect(find.text('Attachment retained'), findsOneWidget);
    expect(
      find.text('Partial response (output token limit reached).'),
      findsOneWidget,
    );
    final latest = find.text('Latest <b>plain</b> response');
    final earlier = find.text('Earlier request');
    expect(
      tester.getSemantics(latest),
      isSemantics(label: 'Latest <b>plain</b> response'),
    );
    expect(
      tester.getTopLeft(earlier).dy,
      lessThan(tester.getTopLeft(latest).dy),
    );
    await _tap(tester, 'Load older messages');
    expect(find.text('Load older messages'), findsNothing);
    expect(earlier, findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Oldest request')).dy,
      lessThan(tester.getTopLeft(earlier).dy),
    );
    expect(client.calls.sublist(3), [
      ('branches', _second, 'branches/+'),
      ('messages', _second, _branch, null),
      ('messages', _second, _branch, 'older/+'),
    ]);

    await _escape(tester);
    expect(find.text('Branches'), findsOneWidget);
    expect(latest, findsNothing);
    await _escape(tester);
    expect(find.text('Personal conversations'), findsOneWidget);
    await _escape(tester);
    expect(find.text('Capabilities'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(open).focusNode!.hasFocus, isTrue);
    semantics.dispose();
  });

  testWidgets('distinguishes no available history from managed empty history', (
    tester,
  ) async {
    final client = _HistorySession();
    client.readBranches = (_, _) async =>
        const HistoryPage([_branchSummary, _otherBranchSummary]);
    client.readMessages = (_, branch, _) async =>
        HistoryPage(const [], historyAvailable: branch == _branch);
    await _openBranches(tester, client);
    await _tap(tester, 'Branch $_otherBranch');
    expect(
      find.text('History is unavailable for this branch.'),
      findsOneWidget,
    );
    expect(find.text('No messages on this branch.'), findsNothing);
    await _tap(tester, 'Back');
    await _tap(tester, 'Branch $_branch');
    expect(find.text('No messages on this branch.'), findsOneWidget);
    expect(find.text('History is unavailable for this branch.'), findsNothing);
  });

  testWidgets('retries transient reads and stops a cycle of opaque cursors', (
    tester,
  ) async {
    var continuation = 0;
    final client = _HistorySession()
      ..readConversations = (cursor) async {
        if (cursor == null) {
          return const HistoryPage([_conversation], nextCursor: 'cursor-one');
        }
        if (continuation++ == 0) throw HistoryFailure.unavailable;
        return HistoryPage([
          _conversation,
          _anotherConversation,
        ], nextCursor: cursor == 'cursor-one' ? 'cursor-two' : 'cursor-one');
      };
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    await _tap(tester, 'Conversations');
    await _tap(tester, 'Load more conversations');
    expect(find.text('Could not load history.'), findsOneWidget);
    expect(find.text('Conversation $_first'), findsOneWidget);
    await _tap(tester, 'Retry');
    await _tap(tester, 'Load more conversations');
    expect(find.text('Load more conversations'), findsNothing);
    expect(find.text('History changed. Reload to continue.'), findsOneWidget);
    expect(find.text('Conversation $_second'), findsNothing);
    await _tap(tester, 'Retry');
    expect(client.calls.map((call) => (call as (String, String?)).$2), [
      null,
      'cursor-one',
      'cursor-one',
      'cursor-two',
      null,
    ]);
    expect(find.text('Conversation $_second'), findsNothing);
  });

  for (final failure in [
    HistoryFailure.invalidCursor,
    HistoryFailure.invalidResponse,
  ]) {
    testWidgets('Retry starts from the branch head after $failure', (
      tester,
    ) async {
      final client = _HistorySession()
        ..readMessages = (_, _, cursor) async {
          if (cursor != null) throw failure;
          return const HistoryPage([_latest], nextCursor: 'older');
        };
      await _openBranches(tester, client);
      await _tap(tester, 'Branch $_branch');
      await _tap(tester, 'Load older messages');
      expect(find.byType(SelectionArea), findsNothing);
      await _tap(tester, 'Retry');
      expect(client.calls.last, ('messages', _first, _branch, null));
      expect(find.byType(SelectionArea), findsOneWidget);
    });
  }

  testWidgets(
    'refusal clears the previous page and expiry signs out globally',
    (tester) async {
      final client = _HistorySession()
        ..readMessages = (_, _, cursor) async => cursor == null
            ? const HistoryPage([_latest], nextCursor: 'older')
            : throw HistoryFailure.inaccessible;
      await _openBranches(tester, client);
      await _tap(tester, 'Branch $_branch');
      await _tap(tester, 'Load older messages');
      expect(find.byType(SelectionArea), findsNothing);
      expect(find.text('This history is unavailable.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);

      await _tap(tester, 'Back');
      client.readMessages = (_, _, _) => throw HistoryFailure.unauthenticated;
      await _tap(tester, 'Branch $_branch');
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Conversations'), findsNothing);
      expect(find.text('Capabilities'), findsNothing);
    },
  );

  testWidgets('drops late transcripts after Back and confirmed sign-out', (
    tester,
  ) async {
    final back = Completer<HistoryPage<HistoryMessage>>();
    final client = _HistorySession()..readMessages = (_, _, _) => back.future;
    await _openBranches(tester, client);
    await _tap(tester, 'Branch $_branch');
    await _tap(tester, 'Back');
    back.complete(const HistoryPage([_latest]));
    await tester.pumpAndSettle();
    expect(find.byType(SelectionArea), findsNothing);

    final message = Completer<HistoryPage<HistoryMessage>>();
    final logout = Completer<void>();
    client.readMessages = (_, _, _) => message.future;
    client.logout = () => logout.future;
    await _tap(tester, 'Branch $_branch');
    final signOut = find.widgetWithText(TextButton, 'Sign out');
    tester.widget<TextButton>(signOut).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    message.complete(const HistoryPage([_latest]));
    await tester.pumpAndSettle();
    expect(find.text('Signing out…'), findsOneWidget);
    expect(find.byType(SelectionArea), findsNothing);
    logout.complete();
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    expect(tester.widget<FilledButton>(signIn).focusNode!.hasFocus, isTrue);
  });

  testWidgets('hide discards history and validates the session on return', (
    tester,
  ) async {
    final client = _HistorySession();
    await _openBranches(tester, client);
    await _tap(tester, 'Branch $_branch');
    expect(find.byType(SelectionArea), findsOneWidget);

    final session = Completer<bool>();
    client.session = () => session.future;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Checking your session…'), findsOneWidget);
    expect(find.text('Conversations'), findsNothing);
    session.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Capabilities'), findsOneWidget);
    expect(find.text('Transcript'), findsNothing);
  });

  testWidgets(
    'a late confirmed expiry clears another view of the same session',
    (tester) async {
      final pending = Completer<HistoryPage<HistoryMessage>>();
      final client = _HistorySession()
        ..readMessages = (_, _, _) => pending.future;
      await _openBranches(tester, client);
      await _tap(tester, 'Branch $_branch');
      await _tap(tester, 'Back');
      expect(find.text('Branches'), findsOneWidget);
      pending.completeError(HistoryFailure.unauthenticated);
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Branches'), findsNothing);
    },
  );

  testWidgets(
    'unknown turn and part states fall back without showing payloads',
    (tester) async {
      final client = _HistorySession()
        ..readMessages = (_, _, _) async => const HistoryPage([
          HistoryMessage(
            id: 'future',
            role: 'future role',
            stopReason: 'future_reason',
            parts: [
              HistoryPart(kind: 'attachment', state: 'future state'),
              HistoryPart(kind: 'future kind', text: 'future payload'),
            ],
          ),
        ]);
      await _openBranches(tester, client);
      await _tap(tester, 'Branch $_branch');
      expect(find.text('Unknown role'), findsOneWidget);
      expect(
        find.text('The server reported an unrecognized stop reason.'),
        findsOneWidget,
      );
      expect(find.text('Attachment unavailable'), findsOneWidget);
      expect(find.text('Unsupported message content'), findsOneWidget);
      expect(find.text('future payload'), findsNothing);
    },
  );

  testWidgets('client replacement ignores a previous session read', (
    tester,
  ) async {
    final pending = Completer<HistoryPage<HistoryMessage>>();
    final original = _HistorySession()
      ..readMessages = (_, _, _) => pending.future;
    await _openBranches(tester, original);
    await _tap(tester, 'Branch $_branch');

    await tester.pumpWidget(OpenMettleApp(client: _Session()));
    await tester.pumpAndSettle();
    pending.completeError(HistoryFailure.unauthenticated);
    await tester.pumpAndSettle();
    expect(find.text('Signed in'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Transcript'), findsNothing);
  });

  testWidgets(
    'long IDs and transcript controls fit large text on narrow screens',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(280, 620));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await _openBranches(tester, _HistorySession());
      final label = find.text('Branch $_branch');
      final rect = tester.getRect(label);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(280));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Back re-reads branches to page two before focusing the chosen row',
    (tester) async {
      final client = _HistorySession();
      await _openSecondPageBranch(tester, client);
      final pages = {
        null: Completer<HistoryPage<BranchSummary>>(),
        'branches/2': Completer<HistoryPage<BranchSummary>>(),
      };
      client.readBranches = (_, cursor) => pages[cursor]!.future;

      await _escape(tester);
      expect(find.text('Branches'), findsOneWidget);
      expect(find.text('Loading history…'), findsOneWidget);
      expect(find.textContaining('Branch 0000'), findsNothing);
      expect(
        _focusedIn(tester, find.widgetWithText(TextButton, 'Back')),
        isTrue,
      );

      pages[null]!.complete(
        const HistoryPage([_branchSummary], nextCursor: 'branches/2'),
      );
      await tester.pumpAndSettle();
      // The first fresh page is not shown while the earlier position is sought.
      expect(find.text('Loading history…'), findsOneWidget);
      expect(find.text('Branch $_branch'), findsNothing);

      pages['branches/2']!.complete(const HistoryPage([_otherBranchSummary]));
      await tester.pumpAndSettle();
      expect(client.calls, [
        ('branches', _first, null),
        ('branches', _first, 'branches/2'),
      ]);
      expect(find.text('Branch $_branch'), findsOneWidget);
      expect(_focusedIn(tester, _row(_otherBranch)), isTrue);
      expect(find.text('Loading history…'), findsNothing);
      expect(find.text('Load more branches'), findsNothing);

      // Enter reopens the restored row; the second Back restores it again.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsOneWidget);
      client.readBranches = (_, cursor) async => cursor == null
          ? const HistoryPage([_branchSummary], nextCursor: 'branches/2')
          : const HistoryPage([_otherBranchSummary]);
      await _escape(tester);
      expect(_focusedIn(tester, _row(_otherBranch)), isTrue);

      client.calls.clear();
      await _escape(tester);
      expect(find.text('Personal conversations'), findsOneWidget);
      expect(client.calls, [('conversations', null)]);
      expect(_focusedIn(tester, _row(_first)), isTrue);
      await _escape(tester);
      expect(find.text('Capabilities'), findsOneWidget);
    },
  );

  testWidgets('Back restores a conversation chosen on page two', (
    tester,
  ) async {
    final client = _HistorySession()
      ..readConversations = (cursor) async => cursor == null
          ? const HistoryPage([_conversation], nextCursor: 'conversations/2')
          : const HistoryPage([_anotherConversation]);
    await tester.pumpWidget(OpenMettleApp(client: client));
    await tester.pumpAndSettle();
    await _tap(tester, 'Conversations');
    await _tap(tester, 'Load more conversations');
    await _tap(tester, 'Conversation $_second');
    client.calls.clear();
    await _tap(tester, 'Back');
    expect(client.calls, [
      ('conversations', null),
      ('conversations', 'conversations/2'),
    ]);
    expect(_focusedIn(tester, _row(_second)), isTrue);
  });

  testWidgets('a row that moved earlier is found without reading further', (
    tester,
  ) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    client.readBranches = (_, _) async => const HistoryPage([
      _otherBranchSummary,
      _branchSummary,
    ], nextCursor: 'branches/2');
    await _escape(tester);
    expect(client.calls, [('branches', _first, null)]);
    expect(_focusedIn(tester, _row(_otherBranch)), isTrue);
    expect(find.text('Load more branches'), findsOneWidget);
  });

  testWidgets(
    'a missing row is announced and focus moves to the first row without '
    'reading past the visited depth',
    (tester) async {
      final client = _HistorySession();
      final semantics = tester.ensureSemantics();
      await _openSecondPageBranch(tester, client);
      // The chosen branch was removed and the server now has more pages.
      client.readBranches = (_, cursor) async => cursor == null
          ? const HistoryPage([_branchSummary], nextCursor: 'branches/2')
          : const HistoryPage([], nextCursor: 'branches/3');
      await _escape(tester);
      expect(client.calls, [
        ('branches', _first, null),
        ('branches', _first, 'branches/2'),
      ]);
      final notice = find.text(
        'Could not find that branch on the pages checked.',
      );
      expect(notice, findsOneWidget);
      expect(
        tester.getSemantics(notice),
        isSemantics(
          label: 'Could not find that branch on the pages checked.',
          isLiveRegion: true,
        ),
      );
      expect(_focusedIn(tester, _row(_branch)), isTrue);
      // Normal paging continues from where the restore stopped.
      await _tap(tester, 'Load more branches');
      expect(client.calls.last, ('branches', _first, 'branches/3'));
      expect(notice, findsNothing);
      semantics.dispose();
    },
  );

  testWidgets('an emptied list keeps focus on Back', (tester) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    client.readBranches = (_, _) async => const HistoryPage([]);
    await _escape(tester);
    expect(find.text('No branches.'), findsOneWidget);
    expect(_focusedIn(tester, find.widgetWithText(TextButton, 'Back')), isTrue);
  });

  testWidgets('a restored row below the fold is scrolled into view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = _HistorySession();
    final firstPage = [
      for (var i = 10; i < 20; i++)
        _branchNamed('00000000-0000-4000-8000-0000000000$i'),
    ];
    await _openSecondPageBranch(tester, client, firstPage: firstPage);
    await _escape(tester);
    expect(
      find.widgetWithText(TextButton, 'Branch $_otherBranch').hitTestable(),
      findsOneWidget,
    );
    final rect = tester.getRect(find.text('Branch $_otherBranch'));
    expect(_focusedIn(tester, _row(_otherBranch)), isTrue);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(360));
    final firstRow = find.text('Branch ${firstPage.first.id}');
    expect(firstRow, findsNothing);
    await tester.scrollUntilVisible(firstRow, -200);
    await tester.pumpAndSettle();
    expect(firstRow.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refusal while restoring clears rows and keeps focus on Back', (
    tester,
  ) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    client.readBranches = (_, cursor) async => cursor == null
        ? const HistoryPage([_branchSummary], nextCursor: 'branches/2')
        : throw HistoryFailure.inaccessible;
    await _escape(tester);
    expect(find.text('This history is unavailable.'), findsOneWidget);
    expect(find.textContaining('Branch 0000'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(_focusedIn(tester, find.widgetWithText(TextButton, 'Back')), isTrue);
  });

  testWidgets('a transient failure while restoring focuses Retry', (
    tester,
  ) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    client.readBranches = (_, cursor) async => cursor == null
        ? const HistoryPage([_branchSummary], nextCursor: 'branches/2')
        : throw HistoryFailure.unavailable;
    await _escape(tester);
    expect(find.text('Could not load history.'), findsOneWidget);
    expect(find.text('Branch $_branch'), findsNothing);
    expect(
      _focusedIn(tester, find.widgetWithText(OutlinedButton, 'Retry')),
      isTrue,
    );
    client.readBranches = (_, _) async =>
        const HistoryPage([_otherBranchSummary]);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.calls.last, ('branches', _first, 'branches/2'));
    expect(find.text('Branch $_otherBranch'), findsOneWidget);
    expect(_focusedIn(tester, _row(_otherBranch)), isTrue);
  });

  testWidgets('a changed cursor while restoring restarts from the head', (
    tester,
  ) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    client.readBranches = (_, cursor) async => cursor == null
        ? const HistoryPage([_branchSummary], nextCursor: 'branches/2')
        : throw HistoryFailure.invalidCursor;
    await _escape(tester);
    expect(find.text('History changed. Reload to continue.'), findsOneWidget);
    expect(find.textContaining('Branch 0000'), findsNothing);
    expect(
      _focusedIn(tester, find.widgetWithText(OutlinedButton, 'Retry')),
      isTrue,
    );
    client.calls.clear();
    client.readBranches = (_, cursor) async => cursor == null
        ? const HistoryPage([_branchSummary], nextCursor: 'fresh')
        : const HistoryPage([_otherBranchSummary]);
    await _tap(tester, 'Retry');
    expect(client.calls, [
      ('branches', _first, null),
      ('branches', _first, 'fresh'),
    ]);
    expect(_focusedIn(tester, _row(_otherBranch)), isTrue);
  });

  testWidgets('expiry while restoring signs out', (tester) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    client.readBranches = (_, cursor) async => cursor == null
        ? const HistoryPage([_branchSummary], nextCursor: 'branches/2')
        : throw HistoryFailure.unauthenticated;
    await _escape(tester);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Branches'), findsNothing);
  });

  testWidgets('navigating away while restoring drops late rows and focus', (
    tester,
  ) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    final late = Completer<HistoryPage<BranchSummary>>();
    client.readBranches = (_, _) => late.future;
    await _escape(tester);
    await _escape(tester);
    expect(find.text('Personal conversations'), findsOneWidget);
    expect(_focusedIn(tester, _row(_first)), isTrue);
    late.complete(const HistoryPage([_otherBranchSummary]));
    await tester.pumpAndSettle();
    expect(find.text('Personal conversations'), findsOneWidget);
    expect(find.textContaining('Branch 0000'), findsNothing);
    expect(_focusedIn(tester, _row(_first)), isTrue);
  });

  testWidgets('a late expiry after leaving a restoring list still signs out', (
    tester,
  ) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    final late = Completer<HistoryPage<BranchSummary>>();
    client.readBranches = (_, _) => late.future;
    await _escape(tester);
    await _escape(tester);
    late.completeError(HistoryFailure.unauthenticated);
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Personal conversations'), findsNothing);
  });

  testWidgets('restoring does not take focus from Sign out', (tester) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    final pending = Completer<HistoryPage<BranchSummary>>();
    client.readBranches = (_, _) => pending.future;
    await _escape(tester);
    final signOut = find.widgetWithText(TextButton, 'Sign out');
    tester.widget<TextButton>(signOut).focusNode!.requestFocus();
    await tester.pump();
    pending.complete(const HistoryPage([_otherBranchSummary]));
    await tester.pumpAndSettle();
    expect(find.text('Branch $_otherBranch'), findsOneWidget);
    expect(_focusedIn(tester, signOut), isTrue);
  });

  testWidgets('hide while restoring clears history and the return position', (
    tester,
  ) async {
    final client = _HistorySession();
    await _openSecondPageBranch(tester, client);
    final pending = Completer<HistoryPage<BranchSummary>>();
    client.readBranches = (_, _) => pending.future;
    await _escape(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpAndSettle();
    pending.complete(const HistoryPage([_otherBranchSummary]));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Capabilities'), findsOneWidget);
    expect(find.text('Branches'), findsNothing);
    expect(find.textContaining('Branch 0000'), findsNothing);

    // Reopening starts without a remembered position.
    client.calls.clear();
    client.readBranches = (_, _) async =>
        const HistoryPage([_branchSummary], nextCursor: 'branches/2');
    await _tap(tester, 'Conversations');
    await _tap(tester, 'Conversation $_first');
    expect(client.calls, [('conversations', null), ('branches', _first, null)]);
    expect(_focusedIn(tester, find.widgetWithText(TextButton, 'Back')), isTrue);
  });
}
