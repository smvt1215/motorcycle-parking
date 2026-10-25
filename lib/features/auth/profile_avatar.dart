import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../ui/adaptive/adaptive.dart';
import '../../data/profile_repository.dart';

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
    final initial =
        (name ?? profileDisplayName(user) ?? '').characters.firstOrNull;
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
                initial.toUpperCase(),
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
