import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../ui/adaptive/adaptive.dart';

/// The heavy-bike silhouette of the 重機專用格 and 普大共用格 badges.
///
/// Licensed from IconScout (Enhanced licence) for use in the app but not
/// for redistribution, so its source never enters this public repository:
/// tool/fetch_heavy_glyph.py writes it here at build time from a private
/// source (a CI secret, or a file on the developer's machine). Builds
/// without it (forks, tests, the admin site) draw [heavyGlyphFallback].
const heavyGlyphAsset = 'assets/private/heavy_glyph.svg';

/// Material's two-wheeler, when the silhouette is absent (user decision).
const heavyGlyphFallback = Icons.two_wheeler;

/// The silhouette once loaded; null before [loadHeavyGlyph] finishes, and
/// for good when the build does not carry it.
final heavyGlyph = ValueNotifier<PictureInfo?>(null);

Future<void>? _loading;

/// Settles when the silhouette has loaded or is known to be absent;
/// completes at once when nothing started loading it.
Future<void> get heavyGlyphSettled => _loading ?? Future<void>.value();

/// Loads the silhouette once. The app calls it at launch; tests and the
/// admin site do not, so they always draw the fallback.
Future<void> loadHeavyGlyph([AssetBundle? bundle]) =>
    _loading ??= _load(bundle ?? rootBundle);

Future<void> _load(AssetBundle bundle) async {
  try {
    final svg = await bundle.loadString(heavyGlyphAsset, cache: false);
    if (!svg.contains('<svg')) return;
    heavyGlyph.value = await vg.loadPicture(SvgStringLoader(svg), null);
  } catch (e) {
    // Absent from this build: the fallback icon stands in.
    debugPrint('重機剪影未載入，改用替代圖示：$e');
  }
}

/// Paints [glyph] in [rect] in [color], facing left like the 大型重型機車
/// road sign (the source faces right). The source is one 24-unit path.
void paintHeavyGlyph(Canvas canvas, PictureInfo glyph, Rect rect, Color color) {
  final size = glyph.size.isEmpty ? const Size.square(24) : glyph.size;
  canvas.save();
  canvas.translate(rect.right, rect.top);
  canvas.scale(-rect.width / size.width, rect.height / size.height);
  canvas.saveLayer(
    Offset.zero & size,
    Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
  );
  canvas.drawPicture(glyph.picture);
  canvas.restore();
  canvas.restore();
}

@visibleForTesting
void resetHeavyGlyph() {
  _loading = null;
  heavyGlyph.value = null;
}
