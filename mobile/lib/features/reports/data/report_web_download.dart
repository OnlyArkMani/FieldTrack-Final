// Web implementation: trigger a real browser download of the report bytes.
// Selected via conditional import (see report_downloader.dart). Only compiled
// for the web target, where `dart:html` is available.
import 'dart:html' as html;
import 'dart:typed_data';

void triggerBrowserDownload(Uint8List bytes, String filename, String mime) {
  final blob = html.Blob(<dynamic>[bytes], mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename
    ..click();
  html.Url.revokeObjectUrl(url);
}
