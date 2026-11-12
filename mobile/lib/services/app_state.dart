import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/report.dart';
import '../models/temperature.dart';
import 'api.dart';
import 'local_store.dart';

class AppState extends ChangeNotifier {
  final LocalStore store;
  final bool firebaseReady;
  final secure = const FlutterSecureStorage();
  late Api api;
  String baseUrl;
  String? userId;
  LatLng? location;
  double accuracy = 0;
  DateTime? _positionAt;
  List<Report> reports = [];
  Map<String, dynamic>? environment;
  Map<String, dynamic>? temperatureLayer;
  bool temperatureLoading = false;
  bool temperatureStale = false;
  String? temperatureError;
  int _temperatureRequest = 0;
  List<Map<String, Object?>> pending = [];
  bool online = false;
  bool initializing = true;
  bool syncing = false;
  bool refreshing = false;
  final Set<String> resolvingReports = {};
  final Set<String> _resolvedIds = {};
  String? message;
  String? alert;
  bool staleEnvironment = true;
  WebSocketChannel? _socket;
  Timer? _timer;
  Timer? _reconnect;
  StreamSubscription? _connectivity;
  StreamSubscription? _gps;
  StreamSubscription? _socketMessages;
  StreamSubscription? _tokenRefresh;
  StreamSubscription? _pushForeground;
  StreamSubscription? _pushOpened;
  String? _fcmToken;
  bool _connecting = false;
  bool _authenticated = false;
  bool _disposed = false;

  AppState(this.store, this.firebaseReady, this.baseUrl) {
    api = Api(baseUrl);
  }
  bool get loggedIn => userId != null;
  int get myReportsCount => pending
      .where((row) => !['EXPIRED', 'RESOLVED'].contains(row['state']))
      .length;
  String get cachePrefix => 'user:$userId';
  bool _visible(Report report) =>
      report.active && !_resolvedIds.contains(report.id);

  Future<void> initialize() async {
    baseUrl = await store.cached('base_url') as String? ?? baseUrl;
    api = Api(baseUrl);
    api.token = await secure.read(key: 'token');
    userId = await secure.read(key: 'user_id');
    if (api.token == null) userId = null;
    initializing = false;
    notifyListeners();
    _connectivity = Connectivity().onConnectivityChanged.listen((_) {
      if (loggedIn) refresh();
    });
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (loggedIn) refresh();
    });
    if (loggedIn) await startSession();
  }

  Future<void> setServer(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ApiError(
        0,
        'Informe o endereço do backend, por exemplo http://192.168.1.10:8000',
      );
    }
    final normalized = (uri.hasPort ? uri : uri.replace(port: 8000))
        .replace(path: '')
        .toString()
        .replaceFirst(RegExp(r'/$'), '');
    if (normalized != baseUrl) {
      await logout();
      baseUrl = normalized;
      api = Api(baseUrl);
      await store.saveCache('base_url', baseUrl);
    }
  }

  Future<void> register(String name, String email, String password) async {
    await api.request(
      'POST',
      '/auth/register',
      body: {'name': name, 'email': email, 'password': password},
    );
  }

  Future<void> login(String email, String password) async {
    final result = await api.request(
      'POST',
      '/auth/login',
      body: {'email': email, 'password': password},
    );
    api.token = result['access_token'] as String;
    userId = result['user_id'] as String;
    await secure.write(key: 'token', value: api.token);
    await secure.write(key: 'user_id', value: userId);
    await startSession();
  }

  Future<void> startSession() async {
    temperatureLayer = null;
    temperatureError = null;
    _resolvedIds.clear();
    final resolved = await store.cached('$cachePrefix:resolved');
    if (resolved is List) _resolvedIds.addAll(resolved.cast<String>());
    final saved = await store.cached('$cachePrefix:reports');
    reports = saved == null
        ? []
        : (saved as List)
              .map((row) => Report(Map<String, dynamic>.from(row)))
              .where(_visible)
              .toList();
    environment =
        await store.cached('$cachePrefix:environment') as Map<String, dynamic>?;
    staleEnvironment = true;
    final point = await store.cached('$cachePrefix:location');
    if (point != null) {
      location = LatLng(
        (point['lat'] as num).toDouble(),
        (point['lng'] as num).toDouble(),
      );
    }
    pending = await store.pending(userId!);
    notifyListeners();
    if (firebaseReady) {
      try {
        await FirebaseMessaging.instance.requestPermission();
        _fcmToken = await FirebaseMessaging.instance.getToken();
        _tokenRefresh ??= FirebaseMessaging.instance.onTokenRefresh.listen((
          token,
        ) {
          _fcmToken = token;
          refresh();
        });
        _pushForeground ??= FirebaseMessaging.onMessage.listen((_) {
          refresh();
        });
        _pushOpened ??= FirebaseMessaging.onMessageOpenedApp.listen((_) {
          refresh();
        });
        await FirebaseMessaging.instance.getInitialMessage();
      } catch (_) {
        message =
            'Push indisponível. Alertas no aplicativo continuam disponíveis.';
      }
    }
    await updateLocation();
    await refresh();
  }

  Future<void> updateLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('Ative a localização do aparelho.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception(
          'Permita o acesso à localização nas configurações do Android.',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      _setPosition(position);
      _gps ??=
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 50,
            ),
          ).listen(
            (position) {
              _setPosition(position);
              refresh();
            },
            onError: (_) {
              message = 'Localização temporariamente indisponível.';
              notifyListeners();
            },
          );
    } catch (error) {
      message = error.toString();
      notifyListeners();
    }
  }

  void _setPosition(Position position) {
    location = LatLng(position.latitude, position.longitude);
    accuracy = position.accuracy;
    _positionAt = position.timestamp.toUtc();
    unawaited(
      store.saveCache('$cachePrefix:location', {
        'lat': position.latitude,
        'lng': position.longitude,
      }),
    );
    _sendLocation();
    notifyListeners();
  }

  Future<void> createReport(String type, String description) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Ative o GPS para registrar a ocorrência.');
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
    final report = {
      'id': const Uuid().v4(),
      'type': type,
      'description': description.trim(),
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy_meters': position.accuracy,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
    };
    await store.enqueue(userId!, report);
    pending = await store.pending(userId!);
    notifyListeners();
    await synchronize();
  }

  Future<void> synchronize() async {
    if (syncing || !loggedIn) return;
    syncing = true;
    notifyListeners();
    try {
      final rows = await store.pending(userId!);
      for (final row in rows) {
        final id = row['id'] as String;
        if (['EXPIRED', 'RESOLVED', 'FAILED'].contains(row['state'])) continue;
        try {
          if (row['state'] != 'QUEUED' && row['state'] != 'SYNCED') {
            await store.state(id, 'SYNCING');
            final payload = Map<String, dynamic>.from(
              jsonDecode(row['payload'] as String),
            );
            await api.request('POST', '/reports', body: payload);
            await store.state(id, 'QUEUED');
          }
          final result = await api.request('GET', '/reports/$id');
          if (result['state'] == 'PROCESSED') await store.state(id, 'SYNCED');
          if (result['state'] == 'EXPIRED') await store.state(id, 'EXPIRED');
          if (result['state'] == 'RESOLVED') await _rememberResolved(id);
          if (result['state'] == 'FAILED') {
            await store.state(
              id,
              'FAILED',
              error: 'Processamento falhou. Tente novamente.',
            );
          }
          online = true;
        } on ApiError catch (error) {
          if (error.status == 401) {
            await logout();
            message =
                'Sua sessão expirou. Faça login; os relatos locais foram preservados.';
            break;
          }
          await store.state(
            id,
            error.status >= 400 && error.status < 500 ? 'FAILED' : 'PENDING',
            error: error.message,
          );
          if (error.status >= 500) {
            online = false;
            break;
          }
        } catch (_) {
          await store.state(
            id,
            'PENDING',
            error: 'Sem acesso ao servidor. O relato está salvo.',
          );
          online = false;
          break;
        }
      }
    } finally {
      if (loggedIn) pending = await store.pending(userId!);
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> retry(String id) async {
    await store.state(id, 'PENDING');
    await synchronize();
  }

  Future<void> loadTemperature(
    double latitude,
    double longitude, {
    bool force = false,
  }) async {
    if (!loggedIn || _disposed) return;
    if (!force &&
        !temperatureStale &&
        temperatureLayer != null &&
        temperatureCovers(temperatureLayer!, latitude, longitude) &&
        temperatureRecent(temperatureLayer!, const Duration(minutes: 10))) {
      return;
    }
    final request = ++_temperatureRequest;
    final owner = userId;
    final prefix = cachePrefix;
    temperatureLoading = true;
    temperatureError = null;
    if (temperatureLayer != null &&
        !temperatureCovers(temperatureLayer!, latitude, longitude)) {
      temperatureLayer = null;
    }
    notifyListeners();
    try {
      final saved = await store.cached('$prefix:temperature');
      if (request != _temperatureRequest || userId != owner || _disposed) {
        return;
      }
      if (saved is Map) {
        final data = Map<String, dynamic>.from(saved);
        if (temperatureCovers(data, latitude, longitude) &&
            temperatureRecent(data, const Duration(hours: 1))) {
          temperatureLayer = data;
          temperatureStale = true;
          notifyListeners();
        }
      }
      final result = Map<String, dynamic>.from(
        await api.request(
          'GET',
          '/environment/temperature-map?lat=$latitude&lng=$longitude',
        ),
      );
      if (request != _temperatureRequest || userId != owner || _disposed) {
        return;
      }
      temperatureLayer = result;
      temperatureStale = false;
      await store.saveCache('$prefix:temperature', result);
    } catch (_) {
      if (request != _temperatureRequest || userId != owner || _disposed) {
        return;
      }
      temperatureStale = true;
      if (temperatureLayer != null &&
          !temperatureRecent(temperatureLayer!, const Duration(hours: 1))) {
        temperatureLayer = null;
      }
      temperatureError = temperatureLayer == null
          ? 'Temperatura indisponível. Confira a conexão e tente novamente.'
          : 'Sem atualização · exibindo os últimos dados salvos.';
    } finally {
      if (request == _temperatureRequest && !_disposed) {
        temperatureLoading = false;
        notifyListeners();
      }
    }
  }

  void cancelTemperatureLoad() {
    _temperatureRequest++;
    temperatureLoading = false;
  }

  Future<void> _rememberResolved(String id) async {
    _resolvedIds.add(id);
    reports.removeWhere((report) => report.id == id);
    await store.state(id, 'RESOLVED');
    await store.saveCache('$cachePrefix:resolved', _resolvedIds.toList());
    await store.saveCache(
      '$cachePrefix:reports',
      reports.map((r) => r.data).toList(),
    );
    if (loggedIn) pending = await store.pending(userId!);
    notifyListeners();
  }

  Future<void> resolveReport(String id) async {
    if (!loggedIn || !resolvingReports.add(id)) return;
    final owner = userId;
    notifyListeners();
    try {
      await api.request('POST', '/reports/$id/resolve');
      if (userId != owner) return;
      await _rememberResolved(id);
      online = true;
    } finally {
      resolvingReports.remove(id);
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (refreshing || !loggedIn) return;
    refreshing = true;
    try {
      await api.request('GET', '/health');
      online = true;
      await synchronize();
      if (!loggedIn) return;
      if (location != null) {
        final point = location!;
        final result = await api.request(
          'GET',
          '/reports/nearby?lat=${point.latitude}&lng=${point.longitude}&radius_meters=3000',
        );
        reports = (result as List)
            .map((row) => Report(Map<String, dynamic>.from(row)))
            .where(_visible)
            .toList();
        await store.saveCache(
          '$cachePrefix:reports',
          reports.map((r) => r.data).toList(),
        );
        if (_positionAt != null) {
          await api.request(
            'PUT',
            '/devices',
            body: {
              'device_id': await store.deviceId(),
              'fcm_token': _fcmToken,
              'latitude': point.latitude,
              'longitude': point.longitude,
              'located_at': _positionAt!.toIso8601String(),
            },
          );
        }
        try {
          environment = Map<String, dynamic>.from(
            await api.request(
              'GET',
              '/environment?lat=${point.latitude}&lng=${point.longitude}',
            ),
          );
          staleEnvironment = false;
          await store.saveCache('$cachePrefix:environment', environment);
        } catch (_) {
          staleEnvironment = true;
        }
        await _connectSocket();
        _sendLocation();
      }
    } on ApiError catch (error) {
      if (error.status == 401) {
        await logout();
        message = 'Sessão expirada. Faça login novamente.';
      } else {
        online = false;
      }
    } catch (_) {
      online = false;
    } finally {
      reports = reports.where(_visible).toList();
      refreshing = false;
      notifyListeners();
    }
  }

  Future<void> _connectSocket() async {
    if (_socket != null || _connecting || !loggedIn || _disposed) return;
    _connecting = true;
    try {
      final uri = Uri.parse(baseUrl);
      final socketUri = uri.replace(
        scheme: uri.scheme == 'https' ? 'wss' : 'ws',
        port: uri.hasPort && uri.port == 8000 ? 8001 : uri.port,
        path: '/ws/alerts',
      );
      final channel = WebSocketChannel.connect(socketUri);
      _socket = channel;
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(jsonEncode({'token': api.token}));
      _socketMessages = channel.stream.listen(
        (raw) {
          final event = jsonDecode(raw as String) as Map<String, dynamic>;
          if (event['type'] == 'authenticated') {
            _authenticated = true;
            _sendLocation();
          }
          if (event['type'] == 'snapshot') {
            reports = (event['reports'] as List)
                .map((row) => Report(Map<String, dynamic>.from(row)))
                .where(_visible)
                .toList();
          } else if (event['type'] == 'report.removed') {
            reports.removeWhere((r) => r.id == event['report_id']);
            if (event['status'] == 'RESOLVED') {
              unawaited(_rememberResolved(event['report_id'] as String));
            }
          } else if (event['report'] != null) {
            final report = Report(Map<String, dynamic>.from(event['report']));
            reports.removeWhere((r) => r.id == report.id);
            if (_visible(report)) {
              reports.add(report);
              if (event['type'] == 'proximity.alert' ||
                  event['notify'] == true) {
                alert = '${reportLabels[report.type]} nas proximidades';
              }
            }
          }
          unawaited(
            store.saveCache(
              '$cachePrefix:reports',
              reports.map((r) => r.data).toList(),
            ),
          );
          notifyListeners();
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _sendLocation() {
    if (location == null || _socket == null || !_authenticated) return;
    _socket!.sink.add(
      jsonEncode({
        'type': 'location.update',
        'latitude': location!.latitude,
        'longitude': location!.longitude,
        'radius_meters': 3000,
      }),
    );
  }

  void _scheduleReconnect() {
    _authenticated = false;
    _socketMessages?.cancel();
    _socket?.sink.close();
    _socket = null;
    _reconnect?.cancel();
    if (loggedIn && !_disposed) {
      _reconnect = Timer(const Duration(seconds: 5), _connectSocket);
    }
  }

  Future<void> logout() async {
    if (loggedIn) {
      try {
        await api.request('DELETE', '/devices/${await store.deviceId()}');
      } catch (_) {}
    }
    userId = null;
    cancelTemperatureLoad();
    temperatureLayer = null;
    temperatureError = null;
    _resolvedIds.clear();
    _authenticated = false;
    api.token = null;
    await secure.delete(key: 'token');
    await secure.delete(key: 'user_id');
    await _gps?.cancel();
    _gps = null;
    await _socketMessages?.cancel();
    _socketMessages = null;
    await _socket?.sink.close();
    _socket = null;
    _reconnect?.cancel();
    location = null;
    _positionAt = null;
    reports = [];
    pending = [];
    environment = null;
    online = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _temperatureRequest++;
    _timer?.cancel();
    _reconnect?.cancel();
    _connectivity?.cancel();
    _gps?.cancel();
    _socketMessages?.cancel();
    _socket?.sink.close();
    _tokenRefresh?.cancel();
    _pushForeground?.cancel();
    _pushOpened?.cancel();
    super.dispose();
  }
}
