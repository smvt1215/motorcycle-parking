import 'dart:async';

import 'package:flutter/services.dart'
    show TextInputFormatter, TextEditingValue;
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import '../../data/account_suspended.dart';
import '../../data/app_store.dart';
import '../../data/repositories.dart' show ReportRefused;
import '../../domain/content_report_display.dart';
import '../../domain/hidden_riders_display.dart';
import '../../domain/spot_contributor.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../account/suspended_sheet.dart';
import '../hidden_riders/hide_rider.dart';
import '../report/report_sheet.dart' show SignInPrompt;

/// How a sent report ended (P17b ④⑥⑦); a failure stays on the form (⑤).
enum ContentReportOutcome { sent, duplicate, limit }

/// Reads the backend's answer to a refused flag by its status only (T280
/// API draft L2): 409 a repeat report, 429 the daily limit. Anything else
/// is a failure, null.
ContentReportOutcome? contentReportRefusal(Object error) => switch (error) {
  FunctionException(status: 409) => ContentReportOutcome.duplicate,
  FunctionException(status: 429) => ContentReportOutcome.limit,
  _ => null,
};

/// The sentence for a 400 whose precheck `issues` name the `note` or
/// the `reason` (Codex #315): a link ([contentReportNoteLink] for
/// `ad_url`), else personal data ([contentReportNotePersonal]); null for
/// any other refusal, which other 400s are (they carry no issues).
String? noteRefusalMessage(Object error) {
  final details = switch (error) {
    ReportRefused(:final details) => details,
    FunctionException(status: 400, :final details) => details,
    _ => null,
  };
  if (details case {'issues': final List<dynamic> issues}) {
    final rules = [
      for (final issue in issues)
        if (issue case {'field': 'note' || 'reason'}) '${issue['rule']}',
    ];
    if (rules.isEmpty) return null;
    return rules.contains('ad_url')
        ? contentReportNoteLink
        : contentReportNotePersonal;
  }
  return null;
}

/// The flag sent for an inappropriate-content report (#280): `field`
/// `inappropriate`, what is wrong in `proposed.target`, and the note.
Map<String, dynamic> contentReportBody(
  ParkingSpot spot,
  ContentReportTarget target,
  String note,
) => {
  'action': 'flag',
  'source_id': spot.id,
  'reason': contentReportReason(target),
  'field': 'inappropriate',
  'proposed': {'target': target.wire},
  if (note.trim().isNotEmpty) 'note': note.trim(),
};

/// The options for [spot]: 車友名稱 only when a rider's public name shows.
List<ContentReportTarget> contentReportTargets(ParkingSpot spot) => [
  for (final t in ContentReportTarget.values)
    if (t != ContentReportTarget.contributorName ||
        publicRiderName(spot).isNotEmpty)
      t,
];

/// 檢舉內容不當 (P17b), from the details' ⋯ or the 修改建議 list. Resolves
/// true when the rider then hid the contributor from a result, so the
/// details can close.
Future<bool> showContentReport(
  BuildContext context,
  AppStore store,
  ParkingSpot spot,
) async {
  var hidden = false;
  await showAdaptiveSheet<void>(
    context,
    (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * .86,
      child: ContentReportSheet(
        store: store,
        spot: spot,
        onHidden: () => hidden = true,
      ),
    ),
  );
  return hidden;
}

class ContentReportSheet extends StatefulWidget {
  const ContentReportSheet({
    super.key,
    required this.store,
    required this.spot,
    this.onHidden,
  });
  final AppStore store;
  final ParkingSpot spot;

  /// Called after the rider hid the contributor from a result.
  final VoidCallback? onHidden;

  @override
  State<ContentReportSheet> createState() => _ContentReportSheetState();
}

class _ContentReportSheetState extends State<ContentReportSheet> {
  final note = TextEditingController();
  ContentReportTarget? target;
  bool sending = false, noteMissing = false;
  String? failure;
  ContentReportOutcome? outcome;

  bool get noteRequired => target == ContentReportTarget.other;

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final picked = target;
    if (picked == null || sending) return;
    if (noteRequired && note.text.trim().isEmpty) {
      setState(() => noteMissing = true);
      return;
    }
    setState(() {
      sending = true;
      failure = null;
    });
    ContentReportOutcome? result;
    AccountSuspended? suspended;
    String? error;
    try {
      await widget.store.submit(
        contentReportBody(widget.spot, picked, note.text),
      );
      result = ContentReportOutcome.sent;
    } on StateError catch (e) {
      // A precheck refusal carries its own sentence; personal data in the
      // note gets the form's own.
      error = !widget.store.canReport
          ? contentReportSignIn
          : noteRefusalMessage(e) ?? e.message.toString();
    } catch (e) {
      // First: a suspended account is no connection failure (#331).
      suspended = accountSuspendedFrom(e);
      if (suspended == null) {
        result = contentReportRefusal(e);
        if (result == null) {
          error = noteRefusalMessage(e) ?? contentReportFailed;
        }
      }
    }
    if (!mounted) return;
    // Send works again before the panel opens, and what was filled in stays
    // for when 知道了 returns here.
    setState(() {
      sending = false;
      outcome = result;
      failure = error;
    });
    if (suspended case final s?) {
      await showSuspendedSheet(context, s.until, untilKnown: s.untilKnown);
    }
  }

  Future<void> _hide() async {
    final handle = widget.store.handleOf(widget.spot);
    if (handle == null) return;
    final done = await hideRider(
      context,
      widget.store,
      handle: handle,
      name: publicRiderName(widget.spot),
      spotName: widget.spot.name,
      onHidden: () {
        widget.onHidden?.call();
        if (mounted) Navigator.pop(context);
      },
    );
    if (!done) return;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final result = outcome;
      final header = [
        _Header(spotName: widget.spot.name, cancel: result == null),
        const Divider(height: 1),
      ];
      final bar = result == null
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: AdaptiveButton(
                  key: const ValueKey('content-report-submit'),
                  label: contentReportSubmit,
                  onPressed:
                      target == null || sending || !widget.store.canReport
                      ? null
                      : () => unawaited(_send()),
                ),
              ),
            )
          : null;
      // The sheet keeps its height; the keyboard takes its bottom, so 送出檢舉
      // sits right above it and the form scrolls the focused field into view
      // (like FormPage).
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: LayoutBuilder(
          // Too short to keep the title above the form as well (a phone on
          // its side with the keyboard up): the title steps aside until the
          // keyboard goes, so the note and 送出檢舉 keep their room. Only the
          // title comes and goes, so the form keeps its state and focus.
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (result != null || box.maxHeight >= _titleMinHeight) ...header,
              Expanded(
                key: const ValueKey('content-report-body'),
                child: result == null
                    ? _form(context)
                    : _result(context, result),
              ),
              ?bar,
            ],
          ),
        ),
      );
    },
  );

  /// Below this height the form drops its title while the keyboard is up.
  static const _titleMinHeight = 300.0;

  Widget _form(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final spot = widget.spot;
    final error = noteMissing && note.text.trim().isEmpty
        ? contentReportNoteMissing
        : null;
    return ListView(
      key: const ValueKey('content-report-form'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      children: [
        if (!widget.store.canReport) ...[
          SignInPrompt(store: widget.store, message: contentReportSignIn),
          const SizedBox(height: 16),
        ],
        Text(
          contentReportIntro,
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text(
            contentReportQuestion,
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        for (final t in contentReportTargets(spot))
          _TargetTile(
            key: ValueKey('content-report-${t.wire}'),
            label: t.label,
            detail: contentReportTargetDetail(
              t,
              riderName: publicRiderName(spot),
              spotName: spot.name,
            ),
            selected: target == t,
            onTap: () => setState(() {
              target = t;
              noteMissing = false;
            }),
          ),
        const SizedBox(height: 12),
        Text(
          contentReportNoteLabel(required: noteRequired),
          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('content-report-note'),
          controller: note,
          // The server counts UTF-16 units (`invalid note` past 500), which
          // the default limit (characters) would let an emoji pass.
          inputFormatters: const [Utf16LengthLimit(contentReportNoteMax)],
          minLines: 2,
          maxLines: 5,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            counterText: '${note.text.length}/$contentReportNoteMax',
            hintText: contentReportNoteHint,
            helperText: contentReportNotePersonal,
            helperMaxLines: 2,
            filled: true,
            border: const OutlineInputBorder(),
            errorText: error,
            errorMaxLines: 3,
          ),
        ),
        if (failure case final message?) ...[
          const SizedBox(height: 8),
          Material(
            key: const ValueKey('content-report-failure'),
            color: colors.errorContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: colors.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(color: colors.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _result(BuildContext context, ContentReportOutcome result) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final (icon, color, title, body) = switch (result) {
      ContentReportOutcome.sent => (
        Icons.check_circle_outline,
        colors.primary,
        contentReportSentTitle,
        contentReportSentBody,
      ),
      ContentReportOutcome.duplicate => (
        Icons.info_outline,
        colors.primary,
        contentReportDuplicateTitle,
        contentReportDuplicateBody,
      ),
      ContentReportOutcome.limit => (
        Icons.schedule,
        conditionalColor,
        contentReportLimitTitle,
        contentReportLimitBody,
      ),
    };
    final handle = widget.store.handleOf(widget.spot);
    final canHide =
        handle != null &&
        !widget.store.ownSpot(widget.spot) &&
        !widget.store.hiddenRiders.isHidden(handle);
    return ListView(
      key: ValueKey('content-report-${result.name}'),
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
      children: [
        Icon(icon, size: 48, color: color),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        if (canHide) ...[
          const SizedBox(height: 20),
          Material(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contentReportHidePrompt, style: text.bodyMedium),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('content-report-hide'),
                    onPressed: () => unawaited(_hide()),
                    style: OutlinedButton.styleFrom(
                      minimumSize: Size(
                        isCupertino ? 44 : 48,
                        isCupertino ? 44 : 48,
                      ),
                    ),
                    icon: const Icon(Icons.visibility_off_outlined),
                    label: const Text(hideRiderAction),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        AdaptiveButton(
          key: const ValueKey('content-report-done'),
          label: contentReportDone,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}

/// iOS: 取消 at the leading edge, the title centred over the spot's name;
/// Android: a close button and the title. Results drop the cancel.
class _Header extends StatelessWidget {
  const _Header({required this.spotName, required this.cancel});
  final String spotName;
  final bool cancel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final titles = Column(
      crossAxisAlignment: isCupertino
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            contentReportTitle,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          spotName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
    final close = cancel
        ? (isCupertino
              ? TextButton(
                  key: const ValueKey('content-report-cancel'),
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                  child: const Text(contentReportCancel),
                )
              : IconButton(
                  key: const ValueKey('content-report-cancel'),
                  tooltip: contentReportCancel,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ))
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
      child: isCupertino
          ? Row(
              children: [
                SizedBox(width: 72, child: close),
                Expanded(child: titles),
                const SizedBox(width: 72),
              ],
            )
          : Row(
              children: [
                ?close,
                if (close == null) const SizedBox(width: 12),
                const SizedBox(width: 4),
                Expanded(child: titles),
              ],
            ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    super.key,
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });
  final String label, detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        button: true,
        child: Material(
          color: selected ? colors.primaryContainer : colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? colors.primary : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: text.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: selected ? colors.primary : colors.outline,
                    ),
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

/// Keeps a field within [max] UTF-16 units, as the server counts; a paste
/// is cut between whole characters.
class Utf16LengthLimit extends TextInputFormatter {
  const Utf16LengthLimit(this.max);
  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length <= max) return newValue;
    final kept = StringBuffer();
    for (final char in newValue.text.characters) {
      if (kept.length + char.length > max) break;
      kept.write(char);
    }
    final text = kept.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
