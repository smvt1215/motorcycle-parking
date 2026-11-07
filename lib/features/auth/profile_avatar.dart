import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/contributor_name.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../data/profile_repository.dart';

/// The account avatar: the name's first letter or digit, else a generic
/// person (P4, P10, P12, P16b). Pictures from sign-in providers are never
/// shown (2026-11-07), whatever the user metadata holds.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, this.user, this.name, this.size = 48});
  final User? user;
  final String? name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // A letter or digit only; emoji, symbols and blank names get the
    // generic person (P16b).
    final initial = avatarInitial(name ?? profilePublicName(user));
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: ColoredBox(
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
                    style: TextStyle(
                      color: colors.onPrimary,
                      fontSize: size * .4,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
