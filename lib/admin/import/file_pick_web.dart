import 'dart:async';
import 'dart:js_interop';

import 'file_pick.dart';

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external _Input createElement(String tag);
}

extension type _Input._(JSObject _) implements JSObject {
  external set type(String value);
  external set accept(String value);
  external _FileList? get files;
  external void click();
  external void addEventListener(String type, JSFunction listener);
}

extension type _FileList._(JSObject _) implements JSObject {
  external int get length;
  external _File? item(int index);
}

extension type _File._(JSObject _) implements JSObject {
  external String get name;
  external JSPromise<JSString> text();
}

/// Opens the browser's file dialog for one JSON file and reads it as text.
/// Nothing leaves the browser until the preview sends it to the RPC.
Future<PickedFile?> pickJsonFile() {
  final done = Completer<PickedFile?>();
  final input = _document.createElement('input')
    ..type = 'file'
    ..accept = '.json,application/json';
  input.addEventListener(
    'change',
    ((JSObject _) {
      final file = input.files?.length == 1 ? input.files!.item(0) : null;
      if (file == null) {
        if (!done.isCompleted) done.complete(null);
        return;
      }
      file.text().toDart.then(
        (text) {
          if (!done.isCompleted) {
            done.complete((name: file.name, text: text.toDart));
          }
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
      );
    }).toJS,
  );
  input.addEventListener(
    'cancel',
    ((JSObject _) {
      if (!done.isCompleted) done.complete(null);
    }).toJS,
  );
  input.click();
  return done.future;
}
