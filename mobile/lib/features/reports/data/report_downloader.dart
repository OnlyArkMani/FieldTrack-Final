// Platform-routing facade for delivering a finished report to the user.
// On web → real browser download (dart:html). On mobile → handled by the
// repository (temp File + share sheet); this facade's web fn is never invoked.
export 'report_web_download_stub.dart'
    if (dart.library.html) 'report_web_download.dart';
