import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/temperature.dart';

class TemperatureMapLayer extends StatelessWidget {
  final Map<String, dynamic> data;
  const TemperatureMapLayer({super.key, required this.data});
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: PolygonLayer(
      polygons: [
        for (final cell in data['cells'] as List)
          Polygon(
            points: [
              LatLng(
                (cell['south'] as num).toDouble(),
                (cell['west'] as num).toDouble(),
              ),
              LatLng(
                (cell['north'] as num).toDouble(),
                (cell['west'] as num).toDouble(),
              ),
              LatLng(
                (cell['north'] as num).toDouble(),
                (cell['east'] as num).toDouble(),
              ),
              LatLng(
                (cell['south'] as num).toDouble(),
                (cell['east'] as num).toDouble(),
              ),
            ],
            color: temperatureColor(
              (cell['temperature_celsius'] as num).toDouble(),
            ).withValues(alpha: 0.36),
            borderStrokeWidth: 0,
          ),
      ],
    ),
  );
}

class TemperatureLegend extends StatelessWidget {
  final Map<String, dynamic>? data;
  final bool loading;
  final bool stale;
  final String? error;
  final VoidCallback onRefresh;
  const TemperatureLegend({
    super.key,
    this.data,
    required this.loading,
    required this.stale,
    this.error,
    required this.onRefresh,
  });

  String get timestamp {
    if (data == null) return '';
    final cells = data!['cells'] as List;
    if (cells.isEmpty) return '';
    final time = DateTime.parse(
      cells.first['weather_time'] as String,
    ).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.day)}/${two(time.month)} ${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('temperature-legend'),
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Temperatura estimada',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const Tooltip(
                message:
                    'Temperatura do ar a 2 m, estimada por modelos regionais. Não mede o calor de cada rua nem comprova ilhas de calor urbanas.',
                child: Icon(Icons.info_outline, size: 18),
              ),
              SizedBox(
                width: 36,
                height: 32,
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: 'Atualizar temperatura',
                        onPressed: onRefresh,
                        icon: const Icon(Icons.refresh, size: 20),
                      ),
              ),
            ],
          ),
          if (data != null) ...[
            Container(
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: const LinearGradient(
                  colors: temperatureColors,
                  stops: temperatureStops,
                ),
              ),
            ),
            DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 12, color: Color(0xFF303030)),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('≤10 °C'),
                  Text('20 °C'),
                  Text('30 °C'),
                  Text('≥40 °C'),
                ],
              ),
            ),
            Text(
              'Open-Meteo · $timestamp · estimativa regional',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if ((data!['missing_cells'] as num? ?? 0) > 0)
              const Text(
                'Áreas sem dados permanecem sem cor.',
                style: TextStyle(fontSize: 11),
              ),
          ] else if (loading)
            const Text('Buscando temperaturas da região…'),
          if (error != null)
            Text(
              error!,
              style: TextStyle(
                fontSize: 12,
                color: stale && data != null
                    ? Colors.brown
                    : Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    ),
  );
}
