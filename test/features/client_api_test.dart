import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/features/kuaiwangyun/client_api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class StorageMock extends Mock implements FlutterSecureStorage {}

class ApiAdapter implements HttpClientAdapter {
  ApiAdapter(this.handler);
  final Map<String, dynamic> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(handler(options)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> payload({
  bool active = true,
  String expiry = '2030-01-01T00:00:00+08:00',
}) => {
  'ok': true,
  'account': {
    'id': 1,
    'username': 'qa',
    'active': active,
    'membership_expires_at': expiry,
  },
  'sources': [
    {
      'id': 1,
      'name': 'Route A',
      'url':
          'https://kuaiwangyun.com/vpn/user/subscribe.php?key=${'a' * 64}&source=1&client=clash',
    },
  ],
  'server_time': '2026-09-09T00:00:00+08:00',
};

void main() {
  test('membership eligibility uses server time and account status', () {
    expect(ClientAccount.fromJson(payload()).canConnect, isTrue);
    expect(ClientAccount.fromJson(payload(active: false)).canConnect, isFalse);
    expect(
      ClientAccount.fromJson(
        payload(expiry: '2020-01-01T00:00:00Z'),
      ).canConnect,
      isFalse,
    );
  });
  test('only HTTPS first-party subscription endpoints are accepted', () {
    for (final url in [
      'http://kuaiwangyun.com/vpn/user/subscribe.php',
      'https://evil.example/vpn/user/subscribe.php',
      'https://kuaiwangyun.com/other',
      'https://name:secret@kuaiwangyun.com/vpn/user/subscribe.php',
      'https://kuaiwangyun.com:8443/vpn/user/subscribe.php',
    ]) {
      expect(
        () => ClientSource.fromJson({'id': 1, 'name': 'A', 'url': url}),
        throwsA(isA<ClientApiException>()),
      );
    }
  });
  test('login stores only bearer token and logout deletes it', () async {
    final storage = StorageMock();
    final token = 'b' * 64;
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((_) async {});
    final requests = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: '$clientWebsite/api/client.php'));
    dio.httpClientAdapter = ApiAdapter((options) {
      requests.add(options);
      return options.queryParameters['action'] == 'logout'
          ? {'ok': true}
          : {...payload(), 'access_token': token};
    });
    final api = ClientApi(dio: dio, storage: storage);
    await api.login(' qa ', 'not-persisted');
    await api.account();
    await api.logout();
    verify(
      () => storage.write(key: 'kuaiwangyun.session.v1', value: token),
    ).called(1);
    verify(() => storage.delete(key: 'kuaiwangyun.session.v1')).called(1);
    expect(requests[0].headers.containsKey('Authorization'), isFalse);
    expect(requests[1].headers['Authorization'], 'Bearer $token');
    expect(requests[0].data, {'username': 'qa', 'password': 'not-persisted'});
    api.close();
  });
}
