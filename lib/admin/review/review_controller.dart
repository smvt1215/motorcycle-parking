import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin_gateway.dart';
import 'review_models.dart';

enum ReviewDecision {
  accept('accepted', '已套用建議'),
  acceptEdited('accepted', '已套用修改'),
  close('accepted', '已結案'),
  reject('rejected', '已駁回');

  const ReviewDecision(this.status, this.done);
  final String status;

  /// Toast text; it names the same action as the button that caused it.
  final String done;
}

/// A decision held back for [ReviewController.undoWindow] so it can be undone;
/// there is no RPC that reopens a resolved report.
class PendingDecision {
  PendingDecision(
    this.report,
    this.decision,
    this.patch,
    this.note, {
    this.force = false,
    this.resolutionKind,
  });
  final ReviewReport report;
  final ReviewDecision decision;
  final Map<String, dynamic> patch;
  final String note;

  /// Why the report is rejected; required for [ReviewDecision.reject].
  final ResolutionKind? resolutionKind;

  /// Applies over a spot changed since the report, after the admin saw it.
  final bool force;
}

class ReviewController extends ChangeNotifier {
  ReviewController(
    this.gateway, {
    this.onResolved,
    this.undoWindow = const Duration(seconds: 6),
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now;

  final AdminGateway? gateway;

  /// Called after a decision is written, to refresh the pending count.
  final VoidCallback? onResolved;
  final Duration undoWindow;
  final DateTime Function() now;

  List<ReviewReport> reports = [];
  Map<String, ReviewSpot> spots = {};
  ReviewKind? filter;
  bool loading = false;
  bool loaded = false;
  String? loadError;

  /// A failed write: the report is back in the queue.
  String? error;
  PendingDecision? pending;

  /// The held-back decision is being written and can no longer be undone.
  bool writing = false;

  List<ReviewSpot> hidden = [];
  bool hiddenLoading = false;
  bool hiddenLoaded = false;
  String? hiddenError;

  /// Reports resolved this session; a slower load must not list them again.
  final Set<String> _resolved = {};

  /// Edited values of decisions that failed to write, by report id.
  final Map<String, Map<String, dynamic>> savedDrafts = {};

  /// Reports whose spot changed after they were sent; the admin has been
  /// shown the newer values and may force the decision.
  final Set<String> conflicts = {};

  /// Conflicts whose current values could not be reloaded. Forcing stays off
  /// for them: the admin must never overwrite values they have not seen.
  final Set<String> unrefreshed = {};

  bool canForce(String id) =>
      conflicts.contains(id) && !unrefreshed.contains(id);

  /// Spots being hidden or restored from the hidden list.
  final Set<String> changing = {};

  String? editingId;
  Map<String, dynamic> draft = {};

  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  /// Reports still to handle; the held-back one is already out of the queue.
  List<ReviewReport> get queue =>
      reports.where((r) => r.id != pending?.report.id).toList();
  List<ReviewReport> get visible =>
      queue.where((r) => filter == null || r.kind == filter).toList();
  int countOf(ReviewKind? kind) =>
      queue.where((r) => kind == null || r.kind == kind).length;

  ReviewReport? byId(String? id) => queue.where((r) => r.id == id).firstOrNull;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (gateway == null || loading) return;
    final generation = _generation;
    loading = true;
    loadError = null;
    _notify();
    try {
      final rows = await gateway!.pendingReports();
      final found = await gateway!.reviewSpots(rows.map((r) => r.sourceId));
      if (generation != _generation) return;
      // A write that finished while this load was in flight already took its
      // report off the queue; the older rows must not bring it back.
      reports = rows.where((r) => !_resolved.contains(r.id)).toList();
      spots = found;
      unrefreshed.clear();
      loaded = true;
    } catch (_) {
      if (generation == _generation) {
        loadError = loaded
            ? '重新載入失敗，目前顯示的可能不是最新資料。請檢查連線後重試。'
            : '待審回報載入失敗，請檢查連線後重試。';
      }
    } finally {
      if (generation == _generation) loading = false;
      _notify();
    }
  }

  /// Drops everything private, e.g. when access is lost or the admin signs out.
  void reset() {
    _generation++;
    _timer?.cancel();
    pending = null;
    writing = false;
    reports = [];
    spots = {};
    loaded = false;
    loading = false;
    loadError = null;
    error = null;
    editingId = null;
    draft = {};
    hidden = [];
    hiddenLoaded = false;
    hiddenLoading = false;
    hiddenError = null;
    changing.clear();
    conflicts.clear();
    savedDrafts.clear();
    _resolved.clear();
    unrefreshed.clear();
    _notify();
  }

  Future<void> loadHidden() async {
    if (gateway == null || hiddenLoading) return;
    final generation = _generation;
    hiddenLoading = true;
    hiddenError = null;
    _notify();
    try {
      final rows = await gateway!.hiddenSpots();
      if (generation != _generation) return;
      hidden = rows;
      hiddenLoaded = true;
    } catch (_) {
      if (generation == _generation) {
        hiddenError = '已隱藏的點位載入失敗，請檢查連線後重試。';
      }
    } finally {
      if (generation == _generation) hiddenLoading = false;
      _notify();
    }
  }

  /// Restores [spot] to the map, or hides it again (undo). Written at once:
  /// the reverse call is the undo.
  Future<bool> setHidden(ReviewSpot spot, bool hide) async {
    if (gateway == null || !changing.add(spot.sourceId)) return false;
    final generation = _generation;
    hiddenError = null;
    _notify();
    try {
      await gateway!.setSpotHidden(spot.sourceId, hide, '');
      if (generation != _generation) return false;
      hidden = hide
          ? [spot, ...hidden.where((s) => s.sourceId != spot.sourceId)]
          : hidden.where((s) => s.sourceId != spot.sourceId).toList();
      return true;
    } catch (_) {
      if (generation == _generation) {
        hiddenError = hide
            ? '「${spot.name}」尚未重新隱藏，請重試。'
            : '「${spot.name}」尚未恢復顯示，請重試。';
      }
      return false;
    } finally {
      if (generation == _generation) changing.remove(spot.sourceId);
      _notify();
    }
  }

  void setFilter(ReviewKind? kind) {
    filter = kind;
    _notify();
  }

  bool editing(String id) => editingId == id;

  void startEdit(ReviewReport report) {
    final spot = spots[report.sourceId];
    editingId = report.id;
    final proposed = spot == null
        ? <String, dynamic>{}
        : applicablePatch(initialProposal(report, spot), spot);
    draft =
        savedDrafts[report.id] ??
        // A gone report without a value starts at the spot's visibility as it
        // is, so the admin chooses to hide it rather than finding the field.
        (proposed.isEmpty && spot != null && report.kind == ReviewKind.gone
            ? {visibilityKey(spot): spot.values[visibilityKey(spot)]}
            : proposed);
    _notify();
  }

  void cancelEdit() {
    editingId = null;
    draft = {};
    _notify();
  }

  void setDraft(String key, Object? value) {
    draft = {...draft, key: value};
    _notify();
  }

  void removeDraft(String key) {
    draft = {...draft}..remove(key);
    _notify();
  }

  /// The patch a decision writes, or why it cannot be written.
  (Map<String, dynamic>, String?) patchFor(
    ReviewReport report,
    ReviewDecision decision,
  ) {
    final spot = spots[report.sourceId];
    if (decision == ReviewDecision.reject || decision == ReviewDecision.close) {
      return (const {}, null);
    }
    if (spot == null) return (const {}, '找不到這個點位，只能駁回。');
    final patch = decision == ReviewDecision.acceptEdited
        ? draft
        : applicablePatch(initialProposal(report, spot), spot);
    if (patch.isEmpty) return (patch, '沒有可套用的變更。');
    return (patch, validatePatch(patch, spot));
  }

  /// Takes [report] out of the queue now and writes the decision after the
  /// undo window. Returns the report to show next, if any.
  Future<String?> decide(
    ReviewReport report,
    ReviewDecision decision,
    String note, {
    bool force = false,
    ResolutionKind? resolutionKind,
  }) async {
    final (patch, problem) = patchFor(report, decision);
    if (decision == ReviewDecision.reject && resolutionKind == null) {
      error = '請先選擇駁回原因。';
      _notify();
      return report.id;
    }
    if (resolutionKind == ResolutionKind.other && note.trim().isEmpty) {
      error = '選「其他原因」時，請在處理說明寫下原因。';
      _notify();
      return report.id;
    }
    if (problem != null) {
      error = problem;
      _notify();
      return report.id;
    }
    // Clear the old message first: a failed write of the previous decision
    // below must stay on screen, not be wiped by this one.
    error = null;
    final generation = _generation;
    await flush();
    // Signed out or access changed meanwhile: this decision belongs to a
    // session that no longer exists and must never be sent.
    if (_disposed || generation != _generation) return null;
    final before = visible;
    final index = before.indexWhere((r) => r.id == report.id);
    pending = PendingDecision(
      report,
      decision,
      patch,
      note,
      force: force,
      resolutionKind: resolutionKind,
    );
    editingId = null;
    draft = {};
    _timer = Timer(undoWindow, () => unawaited(flush()));
    _notify();
    final rest = visible;
    if (rest.isEmpty) return null;
    return rest[index.clamp(0, rest.length - 1)].id;
  }

  /// Puts the held-back report back where it was. Returns its id.
  String? undo() {
    final held = pending;
    if (held == null || writing) return null;
    _timer?.cancel();
    pending = null;
    // Undoing an edited decision returns to the edit, values intact.
    if (held.decision == ReviewDecision.acceptEdited) {
      savedDrafts[held.report.id] = held.patch;
      editingId = held.report.id;
      draft = held.patch;
    }
    _notify();
    return held.report.id;
  }

  /// Reloads [report]'s spot after a conflict; forcing is allowed only once
  /// this has succeeded.
  Future<bool> refreshSpot(ReviewReport report) async {
    if (gateway == null) return false;
    final generation = _generation;
    try {
      final fresh = await gateway!.reviewSpots([report.sourceId]);
      if (generation != _generation || !fresh.containsKey(report.sourceId)) {
        return false;
      }
      spots = {...spots, ...fresh};
      unrefreshed.remove(report.id);
      return true;
    } catch (_) {
      return false;
    } finally {
      _notify();
    }
  }

  /// Writes the held-back decision now (sign-out, a second decision).
  Future<void> flush() async {
    final held = pending;
    if (held == null || gateway == null || writing) return;
    _timer?.cancel();
    final generation = _generation;
    writing = true;
    _notify();
    try {
      await gateway!.resolveReport(
        held.report.id,
        held.decision.status,
        held.patch,
        held.note,
        force: held.force,
        resolutionKind: held.resolutionKind,
      );
      if (generation != _generation) return;
      reports = reports.where((r) => r.id != held.report.id).toList();
      _resolved.add(held.report.id);
      savedDrafts.remove(held.report.id);
      onResolved?.call();
    } catch (e) {
      if (generation != _generation) return;
      // An edited decision that did not land keeps its values, so a retry
      // (or a forced one after a conflict) sends what the admin wrote.
      if (held.decision == ReviewDecision.acceptEdited) {
        savedDrafts[held.report.id] = held.patch;
        if (editingId == null) {
          editingId = held.report.id;
          draft = held.patch;
        }
      }
      final message = e is PostgrestException ? e.message : '';
      if (message.contains('changed since the report')) {
        // The queue item and its detail say so; no separate error banner.
        conflicts.add(held.report.id);
        unrefreshed.add(held.report.id);
        await refreshSpot(held.report);
      } else if (message.contains('already resolved')) {
        reports = reports.where((r) => r.id != held.report.id).toList();
        _resolved.add(held.report.id);
        error = '「${held.report.title}」已由其他人處理，已從佇列移除。';
        onResolved?.call();
      } else {
        error = '「${held.report.title}」尚未處理成功，已放回佇列。請檢查後重試。';
      }
    } finally {
      if (generation == _generation) {
        writing = false;
        if (identical(pending, held)) pending = null;
      }
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
