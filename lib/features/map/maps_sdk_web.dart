import 'dart:js_interop';

import '../../core/config.dart';

@JS('motorcycleLoadGoogleMaps')
external JSPromise<JSAny?> _loadMaps(JSString key);

Future<void> initializeMapsSdk() async {
  await _loadMaps(AppConfig.googleMapsWebKey.toJS).toDart;
}
