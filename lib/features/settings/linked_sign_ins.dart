import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/account_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../auth/brand_sign_in_button.dart';

/// The signed-in account's linked sign-ins (#382), from `identities`;
/// empty signed out or anonymous.
List<LinkedSignIn> linkedSignInsOf(
  User? user, [
  List<UserIdentity>? identities,
]) {
  if (user == null || user.isAnonymous) return const [];
  return linkedSignIns([
    for (final identity in identities ?? user.identities ?? const [])
      (
        provider: identity.provider,
        email: switch (identity.identityData?['email']) {
          final String email => email,
          _ => null,
        },
      ),
  ]);
}

/// 已連結的登入方式 (P19a): read only, below the account card, only for a
/// signed-in account; nothing when the identities cannot be read.
///
/// Starts from `currentUser.identities`, then asks the server once, so an
/// identity linked on another device shows without signing in again.
class LinkedSignInsGroup extends StatefulWidget {
  const LinkedSignInsGroup({super.key, required this.client, this.title});
  final SupabaseClient client;

  /// The group heading, in the page's own group style.
  final Widget? title;

  @override
  State<LinkedSignInsGroup> createState() => _LinkedSignInsGroupState();
}

class _LinkedSignInsGroupState extends State<LinkedSignInsGroup> {
  List<UserIdentity>? fresh;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final identities = await widget.client.auth.getUserIdentities();
      if (mounted && identities.isNotEmpty) {
        setState(() => fresh = identities);
      }
    } catch (_) {
      // Offline or signed out meanwhile: the session's own list stays.
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.client.auth.currentUser;
    // A list fetched for someone else (signed out and in again) is dropped.
    final mine = fresh?.every((i) => i.userId == user?.id) ?? false;
    final rows = linkedSignInsOf(user, mine ? fresh : null);
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      key: const ValueKey('settings-linked-sign-ins'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?widget.title,
        const SizedBox(height: 4),
        for (final row in rows)
          ListTile(
            key: ValueKey('linked-${row.provider.name}'),
            contentPadding: EdgeInsets.zero,
            leading: _BrandMark(row.provider),
            title: Text(row.provider.label),
            subtitle: row.detail == null ? null : Text(row.detail!),
          ),
        const SizedBox(height: 4),
        Text(linkedSignInsAutoLink, style: muted),
        const SizedBox(height: 8),
        Text(linkedSignInsRelayLine(rows), style: muted),
        const SizedBox(height: 28),
      ],
    );
  }
}

/// The sign-in buttons' own Google G and Apple logo (P11), at icon size.
class _BrandMark extends StatelessWidget {
  const _BrandMark(this.provider);
  final SignInProvider provider;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: 24,
      child: switch (provider) {
        SignInProvider.google => const Center(child: GoogleLogo(size: 20)),
        // The logo file is padded: the glyph is 19 of its 44 units tall and
        // sits 2 units above the middle.
        SignInProvider.apple => OverflowBox(
          maxWidth: 32,
          maxHeight: 44,
          child: Transform.translate(
            offset: const Offset(0, 2),
            child: AppleLogo(
              height: 44,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      },
    ),
  );
}
