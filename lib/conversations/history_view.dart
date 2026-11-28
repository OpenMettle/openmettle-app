import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'history.dart';
import 'history_choice.dart';

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

/// The row chosen from a list and how many pages had been read at the time.
typedef _Selection = ({String id, int pages});

class _ConversationHistoryState extends State<ConversationHistoryView> {
  String? _conversationId;
  String? _branchId;
  // Only identifiers are kept for Back; every list is read again on return.
  _Selection? _conversation;
  _Selection? _branch;

  void _back() {
    if (_branchId != null) {
      setState(() => _branchId = null);
    } else if (_conversationId != null) {
      setState(() {
        _conversationId = null;
        _branch = null;
      });
    } else {
      widget.onBack();
    }
  }

  // Do not take focus back from a control the user moved to during the read.
  bool _canMoveFocus() => !widget.signOutFocus.hasFocus;

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
        item: (conversation, pages, focusNode) => HistoryChoice(
          label: 'Conversation ${conversation.id}',
          createdAt: conversation.createdAt,
          focusNode: focusNode,
          onPressed: () => setState(() {
            _conversationId = conversation.id;
            _conversation = (id: conversation.id, pages: pages);
            _branch = null;
          }),
        ),
        heading: heading,
        empty: 'No personal conversations.',
        more: 'Load more conversations',
        restore: _conversation,
        missing: 'Could not find that conversation on the pages checked.',
        canMoveFocus: _canMoveFocus,
        onSessionExpired: widget.onSessionExpired,
      );
    } else if (branchId == null) {
      heading = 'Branches';
      content = _HistoryList<BranchSummary>(
        key: ValueKey(conversationId),
        read: (cursor) => source.branches(conversationId, cursor: cursor),
        idOf: (branch) => branch.id,
        item: (branch, pages, focusNode) => HistoryChoice(
          label: 'Branch ${branch.id}',
          createdAt: branch.createdAt,
          note: branch.historyAvailable ? null : 'History unavailable',
          focusNode: focusNode,
          onPressed: () => setState(() {
            _branchId = branch.id;
            _branch = (id: branch.id, pages: pages);
          }),
        ),
        heading: heading,
        empty: 'No branches.',
        more: 'Load more branches',
        restore: _branch,
        missing: 'Could not find that branch on the pages checked.',
        canMoveFocus: _canMoveFocus,
        onSessionExpired: widget.onSessionExpired,
      );
    } else {
      heading = 'Transcript';
      content = _HistoryList<HistoryMessage>(
        key: ValueKey(branchId),
        read: (cursor) =>
            source.messages(conversationId, branchId, cursor: cursor),
        idOf: (message) => message.id,
        item: (message, _, _) => _Message(message: message),
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
    this.restore,
    this.missing = '',
    this.canMoveFocus,
  });

  final Future<HistoryPage<T>> Function(String? cursor) read;
  final String Function(T) idOf;

  /// Builds a row from its item, the number of pages read so far and the
  /// focus node to attach when the row should receive focus.
  final Widget Function(T, int pages, FocusNode? focusNode) item;
  final String heading;
  final String empty;
  final String more;
  final VoidCallback onSessionExpired;
  final bool chronological;

  /// A row to find and focus after the list is read again from its head.
  final _Selection? restore;

  /// Announced when [restore] is no longer within the pages read before.
  final String missing;
  final bool Function()? canMoveFocus;

  @override
  State<_HistoryList<T>> createState() => _HistoryListState<T>();
}

class _HistoryListState<T> extends State<_HistoryList<T>> {
  final _items = <String, T>{};
  final _requestedCursors = <String>{};
  final _rowFocus = FocusNode();
  final _controlFocus = FocusNode();
  String? _nextCursor;
  int _pages = 0;
  bool _historyAvailable = true;
  bool _loading = true;
  HistoryFailure? _failure;
  // Rows stay hidden while an earlier position is sought.
  late bool _restoring = widget.restore != null;
  bool _restoreMissing = false;
  String? _focusId;

  @override
  void initState() {
    super.initState();
    _read(null);
  }

  @override
  void dispose() {
    _rowFocus.dispose();
    _controlFocus.dispose();
    super.dispose();
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
      final restore = widget.restore;
      var seek = false;
      setState(() {
        _historyAvailable = page.historyAvailable;
        if (!_historyAvailable) {
          _loading = false;
          _restoring = false;
          _items.clear();
          _nextCursor = null;
          return;
        }
        for (final item in page.items) {
          _items.putIfAbsent(widget.idOf(item), () => item);
        }
        _nextCursor = page.nextCursor;
        _pages++;
        if (_restoring && restore != null) {
          final found = _items.containsKey(restore.id);
          // Never read beyond the depth the user had reached before.
          seek = !found && _nextCursor != null && _pages < restore.pages;
          if (!seek) _finishRestore(found ? restore.id : null);
        }
        _loading = seek;
      });
      if (seek) _read(_nextCursor);
    } catch (error) {
      if (error == HistoryFailure.unauthenticated) {
        // The session screen checks that this request still belongs to its
        // current session, even after this list has been replaced.
        onSessionExpired();
        return;
      }
      if (!mounted) return;
      final restoring = _restoring;
      setState(() {
        _loading = false;
        _failure = error is HistoryFailure ? error : HistoryFailure.unavailable;
        if (_failure == HistoryFailure.inaccessible) _restoring = false;
        if (_failure == HistoryFailure.inaccessible ||
            _failure == HistoryFailure.invalidCursor ||
            _failure == HistoryFailure.invalidResponse) {
          _requestedCursors.clear();
          _items.clear();
          _nextCursor = null;
          _pages = 0;
        }
      });
      // A refused list has no controls; focus stays on Back.
      if (restoring && _failure != HistoryFailure.inaccessible) {
        _focusAfterBuild(_controlFocus);
      }
    }
  }

  /// Focuses the restored row, or the first row with an announcement if it
  /// is no longer listed. Called inside setState.
  void _finishRestore(String? id) {
    _restoring = false;
    _restoreMissing = id == null;
    _focusId = id ?? _items.keys.firstOrNull;
    _focusAfterBuild(_focusId == null ? _controlFocus : _rowFocus);
  }

  void _focusAfterBuild(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(widget.canMoveFocus?.call() ?? true)) return;
      final context = node.context;
      if (context == null) return;
      node.requestFocus();
      Scrollable.ensureVisible(context, alignment: 0.5);
    });
  }

  void _load() {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failure = null;
      _restoreMissing = false;
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
      _ when _restoreMissing => widget.missing,
      _ => null,
    };
    final canLoad =
        !_loading &&
        _failure != HistoryFailure.inaccessible &&
        (_failure != null || _nextCursor != null);
    final values = _restoring ? <T>[] : _items.values;
    final items = widget.chronological ? values.toList().reversed : values;
    final notice = status == null
        ? null
        : Semantics(liveRegion: true, child: Text(status));
    final control = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_restoreMissing && notice != null) notice,
        if (canLoad)
          OutlinedButton(
            focusNode: _controlFocus,
            onPressed: _load,
            child: Text(_failure == null ? widget.more : 'Retry'),
          ),
      ],
    );
    final children = <Widget>[
      Semantics(
        header: true,
        child: Text(
          widget.heading,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ),
      const SizedBox(height: 12),
      if (_restoreMissing && notice != null) notice,
      if (widget.chronological) control,
      for (final item in items)
        KeyedSubtree(
          key: ValueKey(widget.idOf(item)),
          child: widget.item(
            item,
            _pages,
            widget.idOf(item) == _focusId ? _rowFocus : null,
          ),
        ),
      if (!widget.chronological) control,
    ];
    const padding = EdgeInsets.fromLTRB(24, 8, 24, 24);
    final focusId = _focusId;
    if (focusId == null || focusId == _items.keys.firstOrNull) {
      return ListView(padding: padding, children: children);
    }
    // Start layout at the verified row. Both sides of the list stay lazy
    // even when item heights differ or the selected row is several pages in.
    final pivot = children.indexWhere(
      (child) => child.key == ValueKey(focusId),
    );
    if (pivot < 0) return ListView(padding: padding, children: children);
    const center = ValueKey('restored history row');
    return Padding(
      padding: padding,
      child: CustomScrollView(
        center: center,
        slivers: [
          SliverList.list(
            children: children.sublist(0, pivot).reversed.toList(),
          ),
          SliverList.list(key: center, children: children.sublist(pivot)),
        ],
      ),
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
