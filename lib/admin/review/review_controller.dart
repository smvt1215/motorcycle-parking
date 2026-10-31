import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/fee.dart';
import '../../models/zone_entries.dart';
import '../spots/lot_models.dart' show jsonList;
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
    Map<String, dynamic>? draft,
  }) : draft = draft ?? patch;
  final ReviewReport report;
  final ReviewDecision decision;
  final Map<String, dynamic> patch;

  /// The edit as the admin left it, before a shared plan choice reshaped
  /// [patch]; an undo or a failed write returns to it.
  final Map<String, dynamic> draft;
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
    this.onSpotChanged,
    this.undoWindow = const Duration(seconds: 6),
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now;

  final AdminGateway? gateway;

  /// Called after a decision is written, to refresh the pending count.
  final VoidCallback? onResolved;

  /// Called after a decision or a restore changed a spot, so the spots
  /// page's list, map and form read it again (決定 49).
  final ValueChanged<String>? onSpotChanged;
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

  /// Official spots purged after deletion, which imports skip (#200).
  List<PurgedOfficialSpot> purged = [];
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
      final gone = await gateway!.purgedOfficialSpots();
      if (generation != _generation) return;
      hidden = rows;
      purged = gone;
      hiddenLoaded = true;
    } catch (_) {
      if (generation == _generation) {
        hiddenError = '已刪除的點位載入失敗，請檢查連線後重試。';
      }
    } finally {
      if (generation == _generation) hiddenLoading = false;
      _notify();
    }
  }

  /// Lets an import bring a purged official spot back (#200).
  Future<bool> releasePurged(PurgedOfficialSpot spot) async {
    if (gateway == null || !changing.add(spot.officialId)) return false;
    final generation = _generation;
    hiddenError = null;
    _notify();
    try {
      await gateway!.releasePurgedOfficial(spot.officialId, '');
      if (generation != _generation) return false;
      purged = purged.where((p) => p.officialId != spot.officialId).toList();
      return true;
    } catch (_) {
      if (generation == _generation) {
        hiddenError = '「${spot.name}」尚未解除，請重試。';
      }
      return false;
    } finally {
      changing.remove(spot.officialId);
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
      onSpotChanged?.call(spot.sourceId);
      return true;
    } catch (_) {
      if (generation == _generation) {
        hiddenError = hide
            ? '「${spot.name}」尚未重新刪除，請重試。'
            : '「${spot.name}」尚未復原，請重試。';
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
    // The fee's text follows it, as in the app's reports; incomplete or
    // invalid amounts and a cleared fee leave the text as it is.
    if (reviewField(key)?.input == FieldInput.fee) {
      final fee = reviewFee(value);
      if (fee != null && fee.valid) {
        draft['fee_note'] = feeNoteOf(fee);
      }
    }
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
    final kept = decision == ReviewDecision.acceptEdited
        ? _entryPatches[report.id]
        : null;
    return (
      {
        ...wirePatch(patch, spot: spot),
        // The patches sent before a conflict, not a new diff (#188).
        for (final MapEntry(:key, :value) in (kept ?? const {}).entries)
          if (patch.containsKey(key)) key: value,
      },
      validatePatch(patch, spot),
    );
  }

  /// Takes [report] out of the queue now and writes the decision after the
  /// undo window. Returns the report to show next, if any.
  Future<String?> decide(
    ReviewReport report,
    ReviewDecision decision,
    String note, {
    bool force = false,
    ResolutionKind? resolutionKind,
    Map<String, dynamic> Function(Map<String, dynamic>)? adjust,
  }) async {
    final (wired, problem) = patchFor(report, decision);
    // How a fee reaches a shared plan, as the admin chose (design §2.6).
    final patch = problem == null && adjust != null ? adjust(wired) : wired;
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
      draft: decision == ReviewDecision.acceptEdited ? {...draft} : null,
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
      savedDrafts[held.report.id] = held.draft;
      editingId = held.report.id;
      draft = held.draft;
    }
    _notify();
    return held.report.id;
  }

  /// The zone and segment patches (#188) an edited decision sent before a
  /// conflict, by report: a retry sends them again as they were, merged onto
  /// the newer lists for the page, never diffed again from a list that
  /// others have changed since.
  final Map<String, Map<String, Object?>> _entryPatches = {};

  /// [report]'s edited lists, the kept patches applied to its spot's
  /// current ones (or set aside when they name an entry no longer there).
  void _rebaseEntries(ReviewReport report) {
    final kept = _entryPatches[report.id];
    final spot = spots[report.sourceId];
    if (kept == null || spot == null) return;
    Map<String, dynamic> rebase(Map<String, dynamic> d) => {
      ...d,
      for (final MapEntry(:key, :value) in kept.entries)
        if (d.containsKey(key))
          key:
              entriesPatch(jsonList(spot.values[key]), value) ??
              StaleEntries(key),
    };
    if (savedDrafts[report.id] case final saved?) {
      savedDrafts[report.id] = rebase(saved);
    }
    if (editingId == report.id) draft = rebase(draft);
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
      _rebaseEntries(report);
      return true;
    } catch (_) {
      return false;
    } finally {
      _notify();
    }
  }

  Future<void> _reloadSpot(String sourceId, int generation) async {
    if (!reports.any((r) => r.sourceId == sourceId)) return;
    try {
      final fresh = await gateway!.reviewSpots([sourceId]);
      if (generation != _generation) return;
      spots = {...spots, ...fresh};
      _notify();
    } catch (_) {
      // The next load or a conflict on apply brings the newer values.
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
      // Deleting the spot (#200) closes its other open reports too.
      final deleted =
          held.patch['hidden'] == true || held.patch['status'] == 'hidden';
      reports = reports
          .where(
            (r) =>
                r.id != held.report.id &&
                !(deleted && r.sourceId == held.report.sourceId),
          )
          .toList();
      _resolved.add(held.report.id);
      savedDrafts.remove(held.report.id);
      _entryPatches.remove(held.report.id);
      onResolved?.call();
      if (held.patch.isNotEmpty) {
        onSpotChanged?.call(held.report.sourceId);
        // Other reports on the same spot compare against its new values.
        unawaited(_reloadSpot(held.report.sourceId, generation));
      }
    } catch (e) {
      if (generation != _generation) return;
      // An edited decision that did not land keeps its values, so a retry
      // (or a forced one after a conflict) sends what the admin wrote.
      if (held.decision == ReviewDecision.acceptEdited) {
        _entryPatches[held.report.id] = {
          for (final key in entryKeys)
            if (held.patch[key] is List) key: held.patch[key],
        };
        savedDrafts[held.report.id] = held.draft;
        if (editingId == null) {
          editingId = held.report.id;
          draft = held.draft;
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
