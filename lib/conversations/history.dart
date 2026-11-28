/// Read-only access to conversations visible in the signed-in user's personal scope.
abstract interface class ConversationSource {
  Future<HistoryPage<ConversationSummary>> conversations({String? cursor});

  Future<HistoryPage<BranchSummary>> branches(
    String conversationId, {
    String? cursor,
  });

  /// Core returns turns from the branch head toward the root.
  Future<HistoryPage<HistoryMessage>> messages(
    String conversationId,
    String branchId, {
    String? cursor,
  });
}

class HistoryPage<T> {
  const HistoryPage(
    this.items, {
    this.nextCursor,
    this.historyAvailable = true,
  });
  final List<T> items;
  final String? nextCursor;
  final bool historyAvailable;
}

class ConversationSummary {
  const ConversationSummary({required this.id, required this.createdAt});
  final String id;
  final String createdAt;
}

class BranchSummary {
  const BranchSummary({
    required this.id,
    required this.createdAt,
    required this.parentBranchId,
    required this.historyAvailable,
  });
  final String id;
  final String createdAt;
  final String? parentBranchId;
  final bool historyAvailable;
}

class HistoryMessage {
  const HistoryMessage({
    required this.id,
    required this.role,
    required this.parts,
    this.runId,
    this.stopReason,
  });
  final String id;
  final String role;
  final List<HistoryPart> parts;
  final String? runId;
  final String? stopReason;
}

class HistoryPart {
  const HistoryPart({
    required this.kind,
    this.text,
    this.state,
    this.revisionId,
  });
  final String kind;
  final String? text;
  final String? state;
  final String? revisionId;
}

enum HistoryFailure implements Exception {
  unauthenticated,
  inaccessible,
  invalidCursor,
  unavailable,
  invalidResponse,
}
