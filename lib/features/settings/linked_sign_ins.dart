import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/account_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../auth/brand_sign_in_button.dart';

/// The server's latest identities (#382), asked once when the settings group
/// opens; `currentUser.identities` does not change with that answer, so the
/// deletion page reads this too and names the same sign-ins as the list.
final refreshedIdentities = ValueNotifier<List<UserIdentity>?>(null);

/// The signed-in account's linked sign-ins (#382), from
/// [refreshedIdentities] when they are [user]'s, else the session's
/// `identities`; empty signed out or anonymous.
List<LinkedSignIn> linkedSignInsOf(User? user) {
  if (user == null || user.isAnonymous) return const [];
  final fresh = refreshedIdentities.value;
  // A list fetched for someone else (signed out and in again) is dropped.
  final mine = fresh?.every((i) => i.userId == user.id) ?? false;
  return linkedSignIns([
    for (final identity in (mine ? fresh : null) ?? user.identities ?? const [])
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
  @override
  void initState() {
    super.initState();
    refreshedIdentities.addListener(_changed);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    refreshedIdentities.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _refresh() async {
    try {
      final identities = await widget.client.auth.getUserIdentities();
      if (identities.isNotEmpty) refreshedIdentities.value = identities;
    } catch (_) {
      // Offline or signed out meanwhile: the last list stays.
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = linkedSignInsOf(widget.client.auth.currentUser);
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
