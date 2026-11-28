import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'history.dart';

class ConversationHistoryView extends StatefulWidget {
  const ConversationHistoryView({
    super.key,
    required this.source,
    required this.onBack,
    required this.onSignOut,
    required this.signOutFocus,
    required this.onSessionExpired,
  });

  final ConversationSource source;
  final VoidCallback onBack;
  final VoidCallback onSignOut;
  final FocusNode signOutFocus;
  final VoidCallback onSessionExpired;

  @override
  State<ConversationHistoryView> createState() => _ConversationHistoryState();
}

class _ConversationHistoryState extends State<ConversationHistoryView> {
  String? _conversationId;
  String? _branchId;

  void _back() {
    if (_branchId != null) {
      setState(() => _branchId = null);
    } else if (_conversationId != null) {
      setState(() => _conversationId = null);
    } else {
      widget.onBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final conversationId = _conversationId;
    final branchId = _branchId;
    final String heading;
    final Widget content;

    if (conversationId == null) {
      heading = 'Personal conversations';
      content = _HistoryList<ConversationSummary>(
        read: (cursor) => source.conversations(cursor: cursor),
        idOf: (conversation) => conversation.id,
        item: (conversation) => _HistoryChoice(
          label: 'Conversation ${conversation.id}',
          createdAt: conversation.createdAt,
          onPressed: () => setState(() => _conversationId = conversation.id),
        ),
        heading: heading,
        empty: 'No personal conversations.',
        more: 'Load more conversations',
        onSessionExpired: widget.onSessionExpired,
      );
    } else if (branchId == null) {
      heading = 'Branches';
      content = _HistoryList<BranchSummary>(
        key: ValueKey(conversationId),
        read: (cursor) => source.branches(conversationId, cursor: cursor),
        idOf: (branch) => branch.id,
        item: (branch) => _HistoryChoice(
          label: 'Branch ${branch.id}',
          createdAt: branch.createdAt,
          note: branch.historyAvailable ? null : 'History unavailable',
          onPressed: () => setState(() => _branchId = branch.id),
        ),
        heading: heading,
        empty: 'No branches.',
        more: 'Load more branches',
        onSessionExpired: widget.onSessionExpired,
      );
    } else {
      heading = 'Transcript';
      content = _HistoryList<HistoryMessage>(
        key: ValueKey(branchId),
        read: (cursor) =>
            source.messages(conversationId, branchId, cursor: cursor),
        idOf: (message) => message.id,
        item: (message) => _Message(message: message),
        heading: heading,
        empty: 'No messages on this branch.',
        more: 'Load older messages',
        chronological: true,
        onSessionExpired: widget.onSessionExpired,
      );
    }

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _back},
      child: Focus(
        child: Scaffold(
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Wrap(
                        spacing: 12,
                        children: [
                          TextButton(
                            key: ValueKey(heading),
                            autofocus: true,
                            onPressed: _back,
                            child: const Text('Back'),
                          ),
                          TextButton(
                            focusNode: widget.signOutFocus,
                            onPressed: widget.onSignOut,
                            child: const Text('Sign out'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: content),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryChoice extends StatelessWidget {
  const _HistoryChoice({
    required this.label,
    required this.createdAt,
    required this.onPressed,
    this.note,
  });

  final String label;
  final String createdAt;
  final VoidCallback onPressed;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton(
              onPressed: onPressed,
              child: Text(label, textAlign: TextAlign.start),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                [createdAt, ?note].join('\n'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryList<T> extends StatefulWidget {
  const _HistoryList({
    super.key,
    required this.read,
    required this.idOf,
    required this.item,
    required this.heading,
    required this.empty,
    required this.more,
    required this.onSessionExpired,
    this.chronological = false,
  });

  final Future<HistoryPage<T>> Function(String? cursor) read;
  final String Function(T) idOf;
  final Widget Function(T) item;
  final String heading;
  final String empty;
  final String more;
  final VoidCallback onSessionExpired;
  final bool chronological;

  @override
  State<_HistoryList<T>> createState() => _HistoryListState<T>();
}

class _HistoryListState<T> extends State<_HistoryList<T>> {
  final _items = <String, T>{};
  final _requestedCursors = <String>{};
  String? _nextCursor;
  bool _historyAvailable = true;
  bool _loading = true;
  HistoryFailure? _failure;

  @override
  void initState() {
    super.initState();
    _read(null);
  }

  Future<void> _read(String? cursor) async {
    final onSessionExpired = widget.onSessionExpired;
    try {
      final page = await Future.sync(() => widget.read(cursor));
      if (!mounted) return;
      if (cursor != null) _requestedCursors.add(cursor);
      if (_requestedCursors.contains(page.nextCursor)) {
        throw HistoryFailure.invalidCursor;
      }
      setState(() {
        _loading = false;
        _historyAvailable = page.historyAvailable;
        if (!_historyAvailable) {
          _items.clear();
          _nextCursor = null;
          return;
        }
        for (final item in page.items) {
          _items.putIfAbsent(widget.idOf(item), () => item);
        }
        _nextCursor = page.nextCursor;
      });
    } catch (error) {
      if (error == HistoryFailure.unauthenticated) {
        // The session screen checks that this request still belongs to its
        // current session, even after this list has been replaced.
        onSessionExpired();
        return;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = error is HistoryFailure ? error : HistoryFailure.unavailable;
        if (_failure == HistoryFailure.inaccessible ||
            _failure == HistoryFailure.invalidCursor ||
            _failure == HistoryFailure.invalidResponse) {
          _requestedCursors.clear();
          _items.clear();
          _nextCursor = null;
        }
      });
    }
  }

  void _load() {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    _read(_nextCursor);
  }

  @override
  Widget build(BuildContext context) {
    final status = switch (_failure) {
      HistoryFailure.inaccessible => 'This history is unavailable.',
      HistoryFailure.invalidCursor => 'History changed. Reload to continue.',
      HistoryFailure.unavailable ||
      HistoryFailure.invalidResponse => 'Could not load history.',
      _ when _loading => 'Loading history…',
      _ when !_historyAvailable => 'History is unavailable for this branch.',
      _ when _items.isEmpty && _nextCursor == null => widget.empty,
      _ => null,
    };
    final canLoad =
        !_loading &&
        _failure != HistoryFailure.inaccessible &&
        (_failure != null || _nextCursor != null);
    final items = widget.chronological
        ? _items.values.toList().reversed
        : _items.values;
    final control = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status != null) Semantics(liveRegion: true, child: Text(status)),
        if (canLoad)
          OutlinedButton(
            onPressed: _load,
            child: Text(_failure == null ? widget.more : 'Retry'),
          ),
      ],
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Semantics(
          header: true,
          child: Text(
            widget.heading,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        const SizedBox(height: 12),
        if (widget.chronological) control,
        for (final item in items)
          KeyedSubtree(
            key: ValueKey(widget.idOf(item)),
            child: widget.item(item),
          ),
        if (!widget.chronological) control,
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.message});

  final HistoryMessage message;

  @override
  Widget build(BuildContext context) {
    final role = switch (message.role) {
      'user' => 'User',
      'assistant' => 'Assistant',
      _ => 'Unknown role',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            container: true,
            header: true,
            child: Text(role, style: Theme.of(context).textTheme.titleSmall),
          ),
          const SizedBox(height: 4),
          if (message.parts.isEmpty) const Text('No message content.'),
          for (final part in message.parts)
            switch ((part.kind, part.state)) {
              ('text', _) => Semantics(
                container: true,
                child: SelectionArea(child: Text(part.text ?? '')),
              ),
              ('attachment', 'active') => const Text('Attachment available'),
              ('attachment', 'retained') => const Text('Attachment retained'),
              ('attachment', _) => const Text('Attachment unavailable'),
              _ => const Text('Unsupported message content'),
            },
          if (message.stopReason != null)
            Text(
              message.stopReason == 'limit'
                  ? 'Partial response (output token limit reached).'
                  : 'The server reported an unrecognized stop reason.',
            ),
        ],
      ),
    );
  }
}
