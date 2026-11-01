import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_version.dart';
import '../../core/config.dart';
import '../../data/account_deletion.dart';
import '../../data/app_store.dart';
import '../../data/profile_repository.dart';
import '../../domain/account_deletion_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/version_text.dart';
import '../auth/profile_avatar.dart';
import '../auth/profile_editor.dart';
import '../auth/sign_in.dart';
import '../map/spot_details.dart' show openDataLicenseUri;
import 'account_deletion_page.dart';

/// The privacy policy and terms URLs (#275); from `--dart-define`, and
/// replaceable in tests. An empty URL hides its row.
@visibleForTesting
({String privacy, String terms}) policyUrls = (
  privacy: AppConfig.privacyPolicyUrl,
  terms: AppConfig.termsUrl,
);

/// 帳號與設定 (P10): the account, 關於 (version, licenses, data sources,
/// privacy policy and terms) and, signed in, 刪除帳號 in its own group.
Future<void> showSettings(BuildContext context, AppStore store) {
  AccountDeletionController? deletion;
  try {
    deletion = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(accountDeletionProvider);
  } catch (_) {
    // Outside the app's ProviderScope (some tests): no deletion entry.
  }
  return showAdaptiveSheet<void>(
    context,
    (ctx) => ContentPage(
      children: [
        // The vehicle is switched beside what it changes: the map's
        // vehicle pill (and the rules page filter), not here.
        SheetTitle('帳號與設定'),
        const SizedBox(height: 16),
        AnimatedBuilder(
          animation: store,
          builder: (ctx, _) => _AccountCard(store: store),
        ),
        const SizedBox(height: 28),
        Text(
          '關於',
          style: Theme.of(ctx).textTheme.titleSmall
              ?.copyWith(color: Theme.of(ctx).colorScheme.primary),
        ),
        const SizedBox(height: 4),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.description_outlined),
          title: const Text('授權資訊'),
          subtitle: const Text('App 使用的開放原始碼套件'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => runAction(ctx, () async {
            final version = await AppVersion.current;
            if (!ctx.mounted) return;
            showLicensePage(
              context: ctx,
              applicationName: '機車停車指南',
              applicationVersion: version.label,
            );
          }),
        ),
        _LinkTile(
          key: const ValueKey('settings-data-license'),
          icon: Icons.verified_outlined,
          title: settingsDataLicense,
          subtitle: settingsDataLicenseDetail,
          uri: openDataLicenseUri,
        ),
        if (Uri.tryParse(policyUrls.privacy) case final uri?
            when policyUrls.privacy.isNotEmpty)
          _LinkTile(
            key: const ValueKey('settings-privacy'),
            icon: Icons.shield_outlined,
            title: settingsPrivacyPolicy,
            uri: uri,
          ),
        if (Uri.tryParse(policyUrls.terms) case final uri?
            when policyUrls.terms.isNotEmpty)
          _LinkTile(
            key: const ValueKey('settings-terms'),
            icon: Icons.gavel_outlined,
            title: settingsTerms,
            uri: uri,
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.info_outline),
          title: const Text('版本'),
          // Selectable, so testers can paste the exact build into feedback.
          subtitle: VersionText(
            selectable: true,
            textAlign: TextAlign.start,
            style: Theme.of(ctx).textTheme.bodyMedium
                ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
          ),
        ),
        if (deletion != null)
          AnimatedBuilder(
            animation: store,
            builder: (ctx, _) => store.riderId == null || store.demo
                ? const SizedBox.shrink()
                : _DeleteAccountGroup(store: store, deletion: deletion!),
          ),
      ],
    ),
  );
}

/// A row that opens [uri] in the browser.
class _LinkTile extends StatelessWidget {
  const _LinkTile({
    super.key,
    required this.icon,
    required this.title,
    required this.uri,
    this.subtitle,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Uri uri;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const Icon(Icons.open_in_new),
    onTap: () => runAction(context, () async {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('無法開啟$title');
      }
    }),
  );
}

/// 刪除帳號 on its own, below everything else, in the destructive color
/// (P15a ①); only for a signed-in Google or Apple account.
class _DeleteAccountGroup extends StatelessWidget {
  const _DeleteAccountGroup({required this.store, required this.deletion});
  final AppStore store;
  final AccountDeletionController deletion;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final danger = destructiveColor(context);
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(isCupertino ? 12 : 16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('settings-delete-account'),
              onTap: () => unawaited(
                openAccountDeletion(context, store: store, deletion: deletion),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: isCupertino
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
                    children: [
                      if (!isCupertino) ...[
                        Icon(Icons.delete_forever_outlined, color: danger),
                        const SizedBox(width: 16),
                      ],
                      Text(
                        settingsDeleteAccount,
                        style: Theme.of(context).textTheme.bodyLarge
                            ?.copyWith(color: danger),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              settingsDeleteFootnote,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who is signed in and what that unlocks: sample data, signed out, or the
/// signed-in account with sign-out.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final user = store.client?.auth.currentUser;
    final signedIn = user != null && !user.isAnonymous;
    final name = profileDisplayName(user);
    final email = user?.email;
    final (title, detail) = store.demo
        ? ('範例模式', '目前使用範例資料。回報只用於功能測試，請勿依範例資料停車。')
        : !signedIn
        ? ('尚未登入', '登入後可回報停車點與同步收藏。瀏覽與記錄停車位置不需登入。')
        // A name heads the card with the email under it; else the email.
        : (
            name ?? email ?? '已登入',
            (name != null ? email : null) ?? '回報與收藏已同步到帳號',
          );
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (signedIn)
                  Semantics(
                    button: true,
                    label: '編輯頭像',
                    child: InkWell(
                      onTap: () => showProfileEditor(context, store),
                      customBorder: const CircleBorder(),
                      child: ProfileAvatar(user: user),
                    ),
                  )
                else
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: colors.surfaceContainerHighest,
                    foregroundColor: colors.onSurfaceVariant,
                    child: Icon(
                      store.demo
                          ? Icons.science_outlined
                          : Icons.person_outline,
                    ),
                  ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    key: const ValueKey('account-title'),
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (signedIn)
                  IconButton(
                    tooltip: '編輯個人資料',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => showProfileEditor(context, store),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              detail,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (!store.demo && !signedIn) ...[
              const SizedBox(height: 16),
              SignInButtons(store: store),
            ],
            if (signedIn) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => runAction(context, () async {
                    await store.signOut();
                    if (context.mounted) Navigator.pop(context);
                  }),
                  child: const Text('登出'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
