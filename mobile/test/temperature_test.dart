import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ecopulse/models/temperature.dart';
import 'package:ecopulse/services/api.dart';
import 'package:ecopulse/services/app_state.dart';
import 'package:ecopulse/services/local_store.dart';
import 'package:ecopulse/screens/temperature_layer.dart';

Map<String, dynamic> grid({int ageMinutes = 0}) => {
  'anchor': {'south': -23.6, 'north': -23.55, 'west': -46.65, 'east': -46.6},
  'cells': [
    {
      'south': -23.6,
      'north': -23.55,
      'west': -46.65,
      'east': -46.6,
      'temperature_celsius': 29.0,
      'weather_time': DateTime.now().toUtc().toIso8601String(),
    },
  ],
  'fetched_at': DateTime.now()
      .subtract(Duration(minutes: ageMinutes))
      .toUtc()
      .toIso8601String(),
  'missing_cells': 0,
};

class TemperatureApi extends Api {
  int calls = 0;
  bool fail = false;
  Completer<dynamic>? response;
  TemperatureApi() : super('http://localhost');
  @override
  Future<dynamic> request(
    String method,
    String route, {
    Map<String, dynamic>? body,
  }) async {
    calls++;
    if (fail) throw ApiError(503, 'offline');
    return response == null ? grid() : response!.future;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test('cores usam escala fixa e cache verifica posição e validade', () {
    expect(temperatureColor(-5), temperatureColors.first);
    expect(temperatureColor(25), temperatureColors[1]);
    expect(temperatureColor(45), temperatureColors.last);
    expect(temperatureCovers(grid(), -23.57, -46.63), isTrue);
    expect(temperatureCovers(grid(), 0, 0), isFalse);
    expect(
      temperatureRecent(grid(ageMinutes: 70), const Duration(hours: 1)),
      isFalse,
    );
  });

  test(
    'carrega sob demanda, reutiliza cache e não mostra outra região offline',
    () async {
      final store = await LocalStore.open(databasePath: inMemoryDatabasePath);
      final state = AppState(store, false, 'http://localhost')..userId = 'one';
      final api = TemperatureApi();
      state.api = api;
      await state.loadTemperature(-23.57, -46.63);
      expect(state.temperatureLayer, isNotNull);
      await state.loadTemperature(-23.571, -46.631);
      expect(api.calls, 1);
      api.fail = true;
      await state.loadTemperature(-23.57, -46.63, force: true);
      expect(state.temperatureStale, isTrue);
      expect(state.temperatureLayer, isNotNull);
      await state.loadTemperature(0, 0);
      expect(state.temperatureLayer, isNull);
      expect(state.temperatureError, isNotNull);
      state.dispose();
      await store.db.close();
    },
  );

  test('desativar a camada ignora resposta atrasada', () async {
    final store = await LocalStore.open(databasePath: inMemoryDatabasePath);
    final state = AppState(store, false, 'http://localhost')..userId = 'one';
    final api = TemperatureApi()..response = Completer<dynamic>();
    state.api = api;
    final pending = state.loadTemperature(-23.57, -46.63);
    while (api.calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    state.cancelTemperatureLoad();
    api.response!.complete(grid());
    await pending;
    expect(state.temperatureLayer, isNull);
    expect(state.temperatureLoading, isFalse);
    state.dispose();
    await store.db.close();
  });

  testWidgets('legenda mostra escala, fonte, horário e atualização', (
    tester,
  ) async {
    var refreshed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: TemperatureLegend(
                data: grid(),
                loading: false,
                stale: false,
                onRefresh: () {
                  refreshed = true;
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Temperatura estimada'), findsOneWidget);
    expect(find.text('≤10 °C'), findsOneWidget);
    expect(find.textContaining('Open-Meteo'), findsOneWidget);
    await tester.tap(find.byTooltip('Atualizar temperatura'));
    expect(refreshed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ativar e desativar remove cores e legenda em tela estreita', (
    tester,
  ) async {
    final fonts = Platform.environment['TEMPERATURE_PREVIEW_FONTS'];
    if (fonts != null) {
      await tester.runAsync(() async {
        for (final entry in {
          'Roboto': 'Roboto-Regular.ttf',
          'MaterialIcons': 'MaterialIcons-Regular.otf',
        }.entries) {
          final bytes = await File('$fonts/${entry.value}').readAsBytes();
          final loader = FontLoader(entry.key)
            ..addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
        }
      });
    }
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var enabled = false;
    var data = grid();
    final previewData = Platform.environment['TEMPERATURE_PREVIEW_DATA'];
    if (previewData != null) {
      data = Map<String, dynamic>.from(
        jsonDecode(File(previewData).readAsStringSync()),
      );
    }
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Roboto',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B4A)),
        ),
        home: StatefulBuilder(
          builder: (context, setState) => RepaintBoundary(
            key: boundary,
            child: Scaffold(
              appBar: AppBar(title: const Text('EcoPulse')),
              body: Column(
                children: [
                  FilterChip(
                    label: const Text('Temperatura estimada'),
                    selected: enabled,
                    onSelected: (value) {
                      setState(() {
                        enabled = value;
                      });
                    },
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        const ColoredBox(
                          color: Color(0xFFE9EEEA),
                          child: SizedBox.expand(),
                        ),
                        FlutterMap(
                          options: const MapOptions(
                            initialCenter: LatLng(-23.57, -46.63),
                            initialZoom: 10,
                          ),
                          children: [
                            if (enabled) TemperatureMapLayer(data: data),
                          ],
                        ),
                        if (enabled)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 20,
                            child: TemperatureLegend(
                              data: data,
                              loading: false,
                              stale: false,
                              onRefresh: () {},
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(TemperatureMapLayer), findsNothing);
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(find.byType(TemperatureMapLayer), findsOneWidget);
    expect(find.byKey(const Key('temperature-legend')), findsOneWidget);
    expect(tester.takeException(), isNull);
    final previewPath = Platform.environment['TEMPERATURE_PREVIEW_PATH'];
    if (previewPath != null) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(previewPath).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(find.byType(TemperatureMapLayer), findsNothing);
    expect(find.byKey(const Key('temperature-legend')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
