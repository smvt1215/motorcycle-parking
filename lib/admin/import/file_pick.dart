/// Choosing a local file in the browser; tests inject their own picker.
library;

export 'file_pick_stub.dart' if (dart.library.js_interop) 'file_pick_web.dart';

/// A chosen text file, or null when the dialog was closed without one.
typedef PickedFile = ({String name, String text});
typedef FilePicker = Future<PickedFile?> Function();
