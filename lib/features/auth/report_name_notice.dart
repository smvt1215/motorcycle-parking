import '../../data/app_store.dart';
import '../../data/profile_repository.dart';
import '../../domain/consent_display.dart';
import '../../domain/contributor_name.dart';
import '../../ui/adaptive/adaptive.dart';
import 'profile_avatar.dart';
import 'profile_editor.dart';

/// Above a new spot's 送出 (P16b A): the wording the spot will show, with
/// 改名稱 (or 設定名稱 when the name stays private) opening P12. Follows the
/// store, so a saved name shows here at once while the form keeps its input.
/// Only for a signed-in account; edits and rider reports never show a name.
class ReportNameNotice extends StatelessWidget {
  const ReportNameNotice({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final user = store.riderId == null
          ? null
          : store.client?.auth.currentUser;
      if (user == null) return const SizedBox.shrink();
      final name = publicContributorName(profileDisplayName(user));
      return _Notice(
        name: name,
        avatarUrl: profileAvatarUrl(user),
        onEdit: () => showProfileEditor(context, store),
      );
    },
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.name,
    required this.avatarUrl,
    required this.onEdit,
  });

  /// The public name, or null when the spot shows only 由車友回報.
  final String? name;
  final String? avatarUrl;
  final VoidCallback onEdit;

  static const _avatar = 28.0, _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final name = this.name;
    final sentence = name == null
        ? TextSpan(text: nameNoticeHidden, style: style)
        : TextSpan(
            style: style,
            children: [
              const TextSpan(text: nameNoticeLead),
              TextSpan(
                text: truncateName(name),
                style: TextStyle(
                  color: colors.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const TextSpan(text: nameNoticeTail),
            ],
          );
    final label = name == null ? nameNoticeSetName : nameNoticeRename;
    final target = isCupertino ? 44.0 : 48.0;
    final buttonStyle = theme.textTheme.labelLarge?.copyWith(
      color: colors.primary,
      fontWeight: FontWeight.w700,
    );
    final button = TextButton(
      key: const ValueKey('report-name-edit'),
      onPressed: onEdit,
      style: TextButton.styleFrom(
        minimumSize: Size(target, target),
        tapTargetSize: MaterialTapTargetSize.padded,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Text(label, style: buttonStyle),
    );
    final avatar = ExcludeSemantics(
      child: ProfileAvatar(
        url: avatarUrl ?? '',
        // A private name shows the generic person, never its letter.
        name: name ?? '',
        size: _avatar,
      ),
    );
    final text = Semantics(
      label: name == null ? nameNoticeHidden : nameNoticeSpoken(name),
      excludeSemantics: true,
      child: Text.rich(sentence, key: const ValueKey('report-name-text')),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        double width(InlineSpan span) {
          final painter = TextPainter(
            text: span,
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final w = painter.width;
          painter.dispose();
          return w;
        }

        // Side by side only when the sentence fits on one line beside the
        // button; otherwise (large text, narrow sheet) the button goes
        // under the sentence.
        final inline =
            _avatar +
                _gap +
                width(sentence) +
                _gap +
                width(TextSpan(text: label, style: buttonStyle)) +
                16 <=
            constraints.maxWidth;
        final lead = Row(
          crossAxisAlignment: inline
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            avatar,
            const SizedBox(width: _gap),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: inline ? 0 : 4),
                child: text,
              ),
            ),
            if (inline) ...[const SizedBox(width: _gap), button],
          ],
        );
        return Padding(
          key: const ValueKey('report-name-notice'),
          padding: const EdgeInsets.only(top: 12),
          child: inline
              ? lead
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    lead,
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: _avatar + _gap - 8,
                      ),
                      child: button,
                    ),
                  ],
                ),
        );
      },
    );
  }
}
