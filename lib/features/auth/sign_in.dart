import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/app_store.dart';
import '../../ui/adaptive/adaptive.dart';

/// Start OAuth where the action is needed, without opening account settings.
class SignInButtons extends StatelessWidget {
  const SignInButtons({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final provider in [
        OAuthProvider.google,
        if (isCupertino) OAuthProvider.apple,
      ]) ...[
        if (provider == OAuthProvider.apple) const SizedBox(height: 12),
        AdaptiveButton(
          label: provider == OAuthProvider.google
              ? '使用 Google 登入'
              : '使用 Apple 登入',
          secondary: provider == OAuthProvider.apple,
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            runAction(context, () => store.signIn(provider));
          },
        ),
      ],
    ],
  );
}

/// A provider picker for compact entry points, dismissed after authentication.
Future<void> showSignIn(BuildContext context, AppStore store) async {
  if (store.canReport) return;
  await showAdaptiveSheet<void>(context, (_) => _SignInSheet(store: store));
}

class _SignInSheet extends StatefulWidget {
  const _SignInSheet({required this.store});
  final AppStore store;

  @override
  State<_SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<_SignInSheet> {
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
  Widget build(BuildContext context) => ContentPage(
    children: [
      SheetTitle('登入'),
      const SizedBox(height: 12),
      const Text('登入後可回報停車資訊與同步收藏。'),
      const SizedBox(height: 24),
      SignInButtons(store: widget.store),
    ],
  );
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
