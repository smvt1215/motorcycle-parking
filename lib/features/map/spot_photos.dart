import '../../ui/adaptive/adaptive.dart';

class SpotPhotos extends StatelessWidget {
  const SpotPhotos({super.key, required this.urls, this.strip = false});

  final List<String> urls;

  /// One scrolling row of thumbnails, as map apps show under place actions.
  final bool strip;

  /// Only https links with a host are loaded.
  static List<String> usable(List<String> urls) => urls
      .map((url) => url.trim())
      .where((url) {
        final uri = Uri.tryParse(url);
        return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
      })
      .toSet()
      .toList();

  @override
  Widget build(BuildContext context) {
    final photos = usable(urls);
    if (photos.isEmpty) {
      return Text(urls.isEmpty ? '尚無照片' : '照片連結無法使用');
    }
    if (strip) {
      return SizedBox(
        height: 148,
        child: ListView.separated(
          key: const ValueKey('spot-photo-strip'),
          scrollDirection: Axis.horizontal,
          itemCount: photos.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) => AspectRatio(
            aspectRatio: photos.length == 1 ? 1.9 : 1.25,
            child: _PhotoTile(photos: photos, index: index),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 320 && photos.length > 1;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < photos.length; index++)
              SizedBox(
                width:
                    twoColumns &&
                        !(photos.length.isOdd && index == photos.length - 1)
                    ? (constraints.maxWidth - 8) / 2
                    : constraints.maxWidth,
                child: AspectRatio(
                  aspectRatio: 1.6,
                  child: _PhotoTile(photos: photos, index: index),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.photos, required this.index});

  final List<String> photos;
  final int index;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Tooltip(
        message: '放大照片 ${index + 1}',
        child: InkWell(
          onTap: () => showSpotPhotoViewer(context, photos, index),
          child: _Photo(
            url: photos[index],
            fit: BoxFit.cover,
            label: '停車點照片 ${index + 1}，點選放大',
          ),
        ),
      ),
    ),
  );
}

class _Photo extends StatelessWidget {
  const _Photo({required this.url, required this.fit, required this.label});

  final String url, label;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => Image.network(
    url,
    width: double.infinity,
    height: double.infinity,
    fit: fit,
    semanticLabel: label,
    loadingBuilder: (context, child, progress) =>
        progress == null ? child : const Center(child: Text('照片載入中')),
    errorBuilder: (context, error, stack) => const Center(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text('照片無法載入', textAlign: TextAlign.center),
      ),
    ),
  );
}

/// The details' photos as 64-point thumbnails (A2): up to [max], the last
/// one standing for the rest (「+2」) when there are more. Each opens the
/// full-screen viewer at that photo.
class SpotPhotoThumbs extends StatelessWidget {
  const SpotPhotoThumbs({super.key, required this.photos, this.max = 4});
  final List<String> photos;
  final int max;

  @override
  Widget build(BuildContext context) {
    final shown = photos.length > max ? max - 1 : photos.length;
    final rest = photos.length - shown;
    final side = isCupertino ? 64.0 : 64.0;
    Widget tile(int index, Widget child, String label) => Semantics(
      button: true,
      label: label,
      // The InkWell below is excluded: assistive taps come here.
      onTap: () => showSpotPhotoViewer(context, photos, index),
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Material(
          color: const Color(0xffdde5dc),
          child: InkWell(
            key: ValueKey('spot-photo-thumb-$index'),
            onTap: () => showSpotPhotoViewer(context, photos, index),
            child: SizedBox.square(dimension: side, child: child),
          ),
        ),
      ),
    );
    return Wrap(
      key: const ValueKey('spot-photo-thumbs'),
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < shown; i++)
          tile(
            i,
            _Photo(url: photos[i], fit: BoxFit.cover, label: ''),
            '放大照片：第 ${i + 1} 張',
          ),
        if (rest > 0)
          tile(
            shown,
            Center(
              child: Text(
                '+$rest',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff16313a),
                ),
              ),
            ),
            '放大照片：另 $rest 張',
          ),
      ],
    );
  }
}

/// Opens [photos] full screen at [initial] (A9): black, 關閉 at the top
/// left, 「1 / 4」, swipe between them, pinch to zoom, and a row of
/// thumbnails to jump. Captions wait for a contract (who took it, when,
/// which zone), so none is shown.
Future<void> showSpotPhotoViewer(
  BuildContext context,
  List<String> photos,
  int initial,
) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    fullscreenDialog: true,
    barrierLabel: '照片',
    pageBuilder: (context, _, _) =>
        SpotPhotoViewer(photos: photos, initial: initial),
    transitionsBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

class SpotPhotoViewer extends StatefulWidget {
  const SpotPhotoViewer({super.key, required this.photos, this.initial = 0});
  final List<String> photos;
  final int initial;

  @override
  State<SpotPhotoViewer> createState() => _SpotPhotoViewerState();
}

class _SpotPhotoViewerState extends State<SpotPhotoViewer> {
  late final pages = PageController(initialPage: widget.initial);
  late int index = widget.initial;

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  void go(int i) => pages.animateToPage(
    i,
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
  );

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    const white = Color(0xffffffff);
    final target = isCupertino ? 44.0 : 48.0;
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark),
      child: Material(
        key: const ValueKey('spot-photo-viewer'),
        color: const Color(0xff000000),
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    IconButton(
                      key: const ValueKey('spot-photo-close'),
                      tooltip: '關閉',
                      constraints: BoxConstraints.tightFor(
                        width: target,
                        height: target,
                      ),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: white),
                    ),
                    Expanded(
                      child: Center(
                        child: Semantics(
                          liveRegion: true,
                          label: '第 ${index + 1} 張，共 ${photos.length} 張',
                          excludeSemantics: true,
                          child: Text(
                            '${index + 1} / ${photos.length}',
                            key: const ValueKey('spot-photo-count'),
                            style: const TextStyle(
                              color: white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Balances the close button so the count stays centred.
                    SizedBox(width: target + 4),
                  ],
                ),
              ),
              Expanded(
                child: PageView.builder(
                  key: const ValueKey('spot-photo-pages'),
                  controller: pages,
                  itemCount: photos.length,
                  onPageChanged: (i) => setState(() => index = i),
                  itemBuilder: (context, i) => InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Center(
                      child: _Photo(
                        url: photos[i],
                        fit: BoxFit.contain,
                        label: '停車點照片 ${i + 1}',
                      ),
                    ),
                  ),
                ),
              ),
              if (photos.length > 1)
                SizedBox(
                  height: 72,
                  child: Semantics(
                    label: '照片列表',
                    container: true,
                    child: ListView.separated(
                      key: const ValueKey('spot-photo-strip-viewer'),
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: photos.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) => Semantics(
                        button: true,
                        selected: i == index,
                        label: '第 ${i + 1} 張照片',
                        onTap: () => go(i),
                        excludeSemantics: true,
                        child: GestureDetector(
                          key: ValueKey('spot-photo-pick-$i'),
                          onTap: () => go(i),
                          child: Container(
                            width: 56,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: i == index ? white : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: _Photo(
                                url: photos[i],
                                fit: BoxFit.cover,
                                label: '',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
