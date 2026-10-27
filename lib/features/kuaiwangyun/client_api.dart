import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const clientWebsite = 'https://kuaiwangyun.com/vpn';

class ClientApiException implements Exception {
  const ClientApiException(this.code);
  final String code;
}

class ClientSource {
  const ClientSource({required this.id, required this.name, required this.url});
  factory ClientSource.fromJson(Map<String, dynamic> json) {
    final uri = Uri.parse(json['url'] as String);
    if (uri.scheme != 'https' ||
        uri.host != 'kuaiwangyun.com' ||
        uri.path != '/vpn/user/subscribe.php' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const ClientApiException('invalid_response');
    }
    return ClientSource(
      id: json['id'] as int,
      name: json['name'] as String,
      url: uri.toString(),
    );
  }
  final int id;
  final String name;
  final String url;
}

class ClientAccount {
  ClientAccount({
    required this.id,
    required this.username,
    required this.active,
    required this.expiresAt,
    required this.sources,
    required this.serverTime,
  });
  factory ClientAccount.fromJson(Map<String, dynamic> json) {
    final account = json['account'] as Map<String, dynamic>;
    return ClientAccount(
      id: account['id'] as int,
      username: account['username'] as String,
      active: account['active'] == true,
      expiresAt: DateTime.tryParse(
        account['membership_expires_at'] as String? ?? '',
      ),
      sources: (json['sources'] as List)
          .map((v) => ClientSource.fromJson(v as Map<String, dynamic>))
          .toList(),
      serverTime: DateTime.parse(json['server_time'] as String),
    );
  }
  final int id;
  final String username;
  final bool active;
  final DateTime? expiresAt;
  final List<ClientSource> sources;
  final DateTime serverTime;
  final Stopwatch elapsed = Stopwatch()..start();
  bool get canConnect =>
      active &&
      expiresAt != null &&
      expiresAt!.isAfter(serverTime.add(elapsed.elapsed));
}

class ClientSourceResponse {
  const ClientSourceResponse({required this.bytes, required this.userInfo});
  final Uint8List bytes;
  final String? userInfo;
}

class ClientApi {
  ClientApi({Dio? dio, FlutterSecureStorage? storage})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: '$clientWebsite/api/client.php',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: false,
              headers: {'Accept': 'application/json'},
            ),
          ),
      _storage = storage ?? const FlutterSecureStorage();
  final Dio _dio;
  final FlutterSecureStorage _storage;
  String? _token;

  // 记住账号密码
  Future<void> saveCredentials(String username, String password) async {
    await _storage.write(key: 'kuaiwangyun.username', value: username);
    await _storage.write(key: 'kuaiwangyun.password', value: password);
    await _storage.write(key: 'kuaiwangyun.remember', value: 'true');
  }

  Future<({String username, String password})?> loadCredentials() async {
    final remember = await _storage.read(key: 'kuaiwangyun.remember');
    if (remember != 'true') return null;
    final username = await _storage.read(key: 'kuaiwangyun.username');
    final password = await _storage.read(key: 'kuaiwangyun.password');
    if (username == null || password == null) return null;
    return (username: username, password: password);
  }

  Future<void> clearCredentials() async {
    await _storage.delete(key: 'kuaiwangyun.username');
    await _storage.delete(key: 'kuaiwangyun.password');
    await _storage.delete(key: 'kuaiwangyun.remember');
  }

  Future<bool> restore() async {
    _token = await _storage.read(key: 'kuaiwangyun.session.v1');
    return _token != null;
  }

  Future<Map<String, dynamic>> _request(
    String action, {
    Map<String, String>? data,
  }) async {
    try {
      final response = await _dio.request<Map<String, dynamic>>(
        '',
        queryParameters: {'action': action},
        data: data,
        options: Options(
          method: data == null ? 'GET' : 'POST',
          headers: {if (_token != null) 'Authorization': 'Bearer $_token'},
        ),
      );
      final body = response.data;
      if (body == null || body['ok'] != true) {
        throw const ClientApiException('invalid_response');
      }
      return body;
    } on DioException catch (error) {
      final body = error.response?.data;
      final code = body is Map ? body['code'] as String? : null;
      throw ClientApiException(code ?? 'network_error');
    }
  }

  Future<ClientAccount> login(String username, String password) async {
    final body = await _request(
      'login',
      data: {'username': username.trim(), 'password': password},
    );
    final account = ClientAccount.fromJson(body);
    final token = body['access_token'] as String;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw const ClientApiException('invalid_response');
    }
    await _storage.write(key: 'kuaiwangyun.session.v1', value: token);
    _token = token;
    return account;
  }

  Future<ClientAccount> account() async =>
      ClientAccount.fromJson(await _request('account'));

  // 卡密兑换
  Future<ClientAccount> redeemCard(String cardCode) async {
    final body = await _request(
      'card_redeem',
      data: {'card_code': cardCode.trim()},
    );
    return ClientAccount.fromJson(body);
  }

  Future<ClientSourceResponse> fetchSource(ClientSource source) async {
    try {
      final response = await _dio.get<Uint8List>(
        source.url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Accept': 'text/yaml, application/yaml, text/plain;q=0.9, */*',
          },
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw const ClientApiException('source_unavailable');
      }
      return ClientSourceResponse(
        bytes: bytes,
        userInfo: response.headers.value('subscription-userinfo'),
      );
    } on ClientApiException {
      rethrow;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw ClientApiException(
        status == 403 || status == 401
            ? 'source_unauthorized'
            : 'source_unavailable',
      );
    }
  }

  Future<void> logout() async {
    try {
      if (_token != null) await _request('logout', data: {});
    } finally {
      await forget();
    }
  }

  Future<void> forget() async {
    _token = null;
    await _storage.delete(key: 'kuaiwangyun.session.v1');
  }

  void close() => _dio.close(force: true);
}

// 全局单例，供其他模块（如 profiles 刷新）使用
final ClientApi globalClientApi = ClientApi();