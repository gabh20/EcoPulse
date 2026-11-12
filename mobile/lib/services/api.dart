import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);
  @override
  String toString() => message;
}

class Api {
  final String baseUrl;
  String? token;
  Api(this.baseUrl);

  Future<dynamic> request(
    String method,
    String route, {
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl$route'));
    request.headers['Content-Type'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) request.body = jsonEncode(body);
    final client = http.Client();
    try {
      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 15));
      dynamic data;
      try {
        data = response.body.isEmpty
            ? null
            : jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw ApiError(
          response.statusCode >= 500 ? response.statusCode : 502,
          'O endereço $baseUrl respondeu, mas não é o servidor do EcoPulse. '
          'Confira o IP do computador e a porta 8000.',
        );
      }
      if (response.statusCode >= 400) {
        final detail = data is Map ? data['detail'] : null;
        throw ApiError(
          response.statusCode,
          detail is String
              ? detail
              : 'Confira os campos informados (${response.statusCode}).',
        );
      }
      return data;
    } finally {
      client.close();
    }
  }
}
