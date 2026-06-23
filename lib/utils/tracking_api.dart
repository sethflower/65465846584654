const String kTrackingApiBaseUrl = 'https://tracking-app.dclink.ua';

Uri trackingApiUri(String path, [Map<String, String>? query]) {
  return Uri.parse(kTrackingApiBaseUrl).replace(
    path: path,
    queryParameters: query,
  );
}
