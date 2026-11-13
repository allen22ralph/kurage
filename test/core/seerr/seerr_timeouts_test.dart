import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/seerr/seerr_api.dart';

void main() {
  test('Seerr requests give up after a while (so rows retry, not hang)', () {
    final dio = Dio();
    SeerrApi(baseUrl: Uri.parse('https://seerr.home.arpa'), dio: dio);
    expect(dio.options.connectTimeout, const Duration(seconds: 10));
    expect(dio.options.receiveTimeout, const Duration(seconds: 30));
  });

  test('a shorter limit set by the caller (the address check) is kept', () {
    final dio = Dio()..options.connectTimeout = const Duration(seconds: 3);
    SeerrApi(baseUrl: Uri.parse('https://seerr.home.arpa'), dio: dio);
    expect(dio.options.connectTimeout, const Duration(seconds: 3));
  });
}
