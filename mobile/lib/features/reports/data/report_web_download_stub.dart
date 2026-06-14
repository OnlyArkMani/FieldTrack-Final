// Non-web stub. On mobile/desktop the report is saved to a temp File and shared
// via the system sheet instead — this path is never called there.
import 'dart:typed_data';

void triggerBrowserDownload(Uint8List bytes, String filename, String mime) {
  throw UnsupportedError('Browser download is only available on web.');
}
