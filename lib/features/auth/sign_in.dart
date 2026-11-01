import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/policy_links.dart';
import '../../data/app_store.dart';
import '../../domain/account_display.dart';
import '../../domain/consent_display.dart';
import '../../ui/adaptive/adaptive.dart';

/// Start OAuth where the action is needed, without opening account settings.
/// The consent (P16a) sits right under the buttons wherever they appear.
class SignInButtons extends StatelessWidget {
  const SignInButtons({super.key, required this.store});
  final AppStore store;

  /// iOS leads with Apple (HIG: Sign in with Apple first and prominent);
  /// elsewhere Google is the only provider.
  static List<OAuthProvider> get providers => isCupertino
      ? const [OAuthProvider.apple, OAuthProvider.google]
      : const [OAuthProvider.google];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, provider) in providers.indexed) ...[
        if (i > 0) const SizedBox(height: 12),
        // One node: the button's label plus what signing in agrees to.
        MergeSemantics(
          child: Semantics(
            hint: consentHint,
            child: AdaptiveButton(
              key: ValueKey('sign-in-${provider.name}'),
              label: provider == OAuthProvider.google
                  ? '使用 Google 登入'
                  : '使用 Apple 登入',
              secondary: i > 0,
              onPressed: () {
                FocusManager.instance.primaryFocus?.unfocus();
                runAction(context, () => store.signIn(provider));
              },
            ),
          ),
        ),
      ],
      const SizedBox(height: 12),
      const SignInConsent(),
    ],
  );
}

/// 登入即表示你已年滿 18 歲，並同意〈服務條款〉與〈隱私權政策〉 (P16a).
/// The links are separate text buttons in a [Wrap], not tappable spans, so
/// each keeps a full touch target and 〈隱私權政策〉 wraps when space runs out.
/// Without both URLs (a development build) the sentence is plain text with
/// a 僅開發用 badge; a release build fails its config check instead (#262).
class SignInConsent extends StatelessWidget {
  const SignInConsent({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final terms = policyUri(policyUrls.terms);
    final privacy = policyUri(policyUrls.privacy);
    if (terms == null || privacy == null) {
      return Column(
        key: const ValueKey('sign-in-consent-dev'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(consentPlain, style: quiet),
          const SizedBox(height: 6),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.tertiaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                consentDevOnly,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onTertiaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      key: const ValueKey('sign-in-consent'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(consentLead, style: quiet),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _ConsentLink(
              key: const ValueKey('consent-terms'),
              title: consentTerms,
              uri: terms,
            ),
            ExcludeSemantics(child: Text(consentAnd, style: quiet)),
            _ConsentLink(
              key: const ValueKey('consent-privacy'),
              title: consentPrivacy,
              uri: privacy,
            ),
          ],
        ),
      ],
    );
  }
}

/// A policy link opened in the in-app browser (SFSafariViewController,
/// Chrome Custom Tabs), so closing it returns to sign-in unchanged.
class _ConsentLink extends StatelessWidget {
  const _ConsentLink({super.key, required this.title, required this.uri});
  final String title;
  final Uri uri;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final target = isCupertino ? 44.0 : 48.0;
    void open() => runAction(context, () async {
      if (!await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) {
        throw StateError(consentOpenFailed(title));
      }
    });
    return Semantics(
      link: true,
      label: title,
      onTap: open,
      excludeSemantics: true,
      child: TextButton(
        onPressed: open,
        style: TextButton.styleFrom(
          minimumSize: Size(target, target),
          tapTargetSize: MaterialTapTargetSize.padded,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          foregroundColor: color,
        ),
        child: Text(
          consentLinkText(title),
          style: theme.textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: color,
          ),
        ),
      ),
    );
  }
}

/// A provider picker for compact entry points, dismissed after authentication.
Future<void> showSignIn(BuildContext context, AppStore store) async {
  if (store.canReport) return;
  await showAdaptiveSheet<void>(context, (_) => SignInSheet(store: store));
}

/// 登入 (P11, P16a): the title and intro scroll when large text needs it,
/// while the buttons and consent stay together at the bottom; when that
/// group alone is taller than the sheet, the whole sheet scrolls.
@visibleForTesting
class SignInSheet extends StatefulWidget {
  const SignInSheet({super.key, required this.store});
  final AppStore store;

  @override
  State<SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<SignInSheet> {
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  void _onAuthChanged() {
    if (!widget.store.canReport) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.pop(context);
      }
    });
  }

  @override
  void dispose() {
    widget.store.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intro = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          key: const ValueKey('sign-in-sheet-scroll'),
          child: _PinnedFooter(
            maxHeight: constraints.maxHeight,
            body: SingleChildScrollView(
              key: const ValueKey('sign-in-intro-scroll'),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SheetTitle('登入'),
                  const SizedBox(height: 8),
                  Text(signInIntro, style: intro),
                  Text(signInNotNeeded, style: intro),
                ],
              ),
            ),
            footer: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              child: SignInButtons(store: widget.store),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays [footer] out at its natural height under [body]. While the footer
/// fits in [maxHeight], [body] gets what is left (a scroll view there
/// scrolls on its own) and the footer stays in view; when the footer alone
/// is taller, both take their natural height so an enclosing scroll view
/// scrolls them together.
class _PinnedFooter extends MultiChildRenderObjectWidget {
  _PinnedFooter({
    required this.maxHeight,
    required Widget body,
    required Widget footer,
  }) : super(children: [body, footer]);
  final double maxHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPinnedFooter(maxHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPinnedFooter renderObject,
  ) => renderObject.maxHeight = maxHeight;
}

class _PinnedFooterData extends ContainerBoxParentData<RenderBox> {}

class _RenderPinnedFooter extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PinnedFooterData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PinnedFooterData> {
  _RenderPinnedFooter(this._maxHeight);
  double _maxHeight;
  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PinnedFooterData) {
      child.parentData = _PinnedFooterData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => [
    for (var c = firstChild; c != null; c = childAfter(c))
      c.getMinIntrinsicWidth(double.infinity),
  ].fold(0, (a, b) => a > b ? a : b);

  @override
  double computeMaxIntrinsicWidth(double height) => [
    for (var c = firstChild; c != null; c = childAfter(c))
      c.getMaxIntrinsicWidth(double.infinity),
  ].fold(0, (a, b) => a > b ? a : b);

  @override
  double computeMinIntrinsicHeight(double width) => [
    for (var c = firstChild; c != null; c = childAfter(c))
      c.getMinIntrinsicHeight(width),
  ].fold(0, (a, b) => a + b);

  @override
  double computeMaxIntrinsicHeight(double width) => [
    for (var c = firstChild; c != null; c = childAfter(c))
      c.getMaxIntrinsicHeight(width),
  ].fold(0, (a, b) => a + b);

  @override
  void performLayout() {
    final body = firstChild!, footer = lastChild!;
    final width = constraints.maxWidth;
    footer.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
    final footerHeight = footer.size.height;
    final room = _maxHeight.isFinite && footerHeight <= _maxHeight
        ? _maxHeight - footerHeight
        : double.infinity;
    body.layout(
      BoxConstraints(minWidth: width, maxWidth: width, maxHeight: room),
      parentUsesSize: true,
    );
    (body.parentData! as _PinnedFooterData).offset = Offset.zero;
    (footer.parentData! as _PinnedFooterData).offset = Offset(
      0,
      body.size.height,
    );
    size = constraints.constrain(Size(width, body.size.height + footerHeight));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Above the navigator, so feedback stays visible over an open report sheet.
/// Only a signed-out → signed-in transition produces a toast; normal refreshes
/// and an already-restored session do not repeat it or change navigation.
class AuthFeedback extends StatefulWidget {
  const AuthFeedback({super.key, required this.store, required this.child});
  final AppStore store;
  final Widget child;

  @override
  State<AuthFeedback> createState() => _AuthFeedbackState();
}

class _AuthFeedbackState extends State<AuthFeedback> {
  late bool signedIn;
  bool visible = false;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    signedIn = widget.store.canReport;
    widget.store.addListener(_onAuthChanged);
  }

  void _onAuthChanged() {
    final next = widget.store.canReport;
    if (next == signedIn) return;
    signedIn = next;
    timer?.cancel();
    setState(() => visible = next);
    if (next) {
      timer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => visible = false);
      });
    }
  }

  @override
  void didUpdateWidget(AuthFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onAuthChanged);
      widget.store.addListener(_onAuthChanged);
      signedIn = widget.store.canReport;
      visible = false;
      timer?.cancel();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.store.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (visible)
          Positioned(
            left: 24,
            right: 24,
            bottom: 20 + MediaQuery.viewInsetsOf(context).bottom,
            child: IgnorePointer(
              child: SafeArea(
                top: false,
                child: Semantics(
                  liveRegion: true,
                  child: Material(
                    key: const ValueKey('auth-success-toast'),
                    color: colors.inverseSurface,
                    borderRadius: BorderRadius.circular(16),
                    elevation: 6,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      child: Text(
                        '登入成功',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onInverseSurface),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
