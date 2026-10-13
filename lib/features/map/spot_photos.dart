import '../../ui/adaptive/adaptive.dart';

class SpotPhotos extends StatelessWidget {
  const SpotPhotos({super.key, required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    final photos = urls
        .map((url) => url.trim())
        .where((url) {
          final uri = Uri.tryParse(url);
          return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
        })
        .toSet()
        .toList();
    if (photos.isEmpty) {
      return Text(urls.isEmpty ? '尚無照片' : '照片連結無法使用');
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
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: Tooltip(
                        message: '放大照片 ${index + 1}',
                        child: InkWell(
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (context) => Dialog.fullscreen(
                              child: SafeArea(
                                child: Column(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text('照片 ${index + 1}'),
                                          ),
                                          IconButton(
                                            tooltip: '關閉照片',
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            icon: const Icon(Icons.close),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: InteractiveViewer(
                                        minScale: 1,
                                        maxScale: 4,
                                        child: Center(
                                          child: _Photo(
                                            url: photos[index],
                                            fit: BoxFit.contain,
                                            label: '停車點照片 ${index + 1}',
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          child: _Photo(
                            url: photos[index],
                            fit: BoxFit.cover,
                            label: '停車點照片 ${index + 1}，點選放大',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
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
