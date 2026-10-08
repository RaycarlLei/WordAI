import 'dart:io';

/// A scenario fails even if production code catches a denied network request.
class OfflineHttp extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Network is disabled in this scenario');
  }
}
