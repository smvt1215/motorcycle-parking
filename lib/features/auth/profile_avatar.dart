import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/contributor_name.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../data/profile_repository.dart';

/// The account photo, or the default avatar: the name's first letter or
/// digit, else a generic person (P4, P10, P12, P16b).
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    this.user,
    this.bytes,
    this.url,
    this.name,
    this.size = 48,
  });
  final User? user;
  final Uint8List? bytes;
  final String? url, name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // A letter or digit only; emoji, symbols and blank names get the
    // generic person (P16b).
    final initial = avatarInitial(name ?? profileDisplayName(user));
    final fallback = ColoredBox(
      color: colors.primary,
      child: Center(
        child: initial == null
            ? Icon(
                Icons.person_outline,
                color: colors.onPrimary,
                size: size * .5,
              )
            : Text(
                initial,
                style: TextStyle(color: colors.onPrimary, fontSize: size * .4),
              ),
      ),
    );
    final address = url ?? profileAvatarUrl(user);
    final image = bytes != null
        ? Image.memory(
            bytes!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          )
        : address != null && address.isNotEmpty
        ? Image.network(
            address,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          )
        : fallback;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(child: image),
    );
  }
}
