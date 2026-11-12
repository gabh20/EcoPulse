import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

class HeatIslandLayer extends StatelessWidget {
  final DateTime day;
  const HeatIslandLayer({super.key, required this.day});

  static const period = Duration(days: 8);

  static DateTime latestDay([DateTime? date]) {
    final reference = (date ?? DateTime.now()).toUtc().subtract(period);
    final start = DateTime.utc(reference.year);
    final periodIndex = reference.difference(start).inDays ~/ period.inDays;
    return start.add(Duration(days: periodIndex * period.inDays));
  }

  static String dateKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  static String tileUrl(DateTime day) =>
      'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/'
      'MODIS_Terra_L3_Land_Surface_Temp_8Day_Day/default/${dateKey(day)}/'
      'GoogleMapsCompatible_Level7/{z}/{y}/{x}.png';

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: 0.72,
    child: TileLayer(
      key: ValueKey(dateKey(day)),
      urlTemplate: tileUrl(day),
      userAgentPackageName: 'br.edu.ecopulse',
      maxNativeZoom: 7,
      maxZoom: 19,
    ),
  );
}

class HeatIslandLegend extends StatelessWidget {
  final DateTime day;
  final bool canGoForward;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  const HeatIslandLegend({
    super.key,
    required this.day,
    required this.canGoForward,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) => Card(
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
                  'Potenciais ilhas de calor',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Dia anterior',
                onPressed: onPrevious,
                icon: const Icon(Icons.chevron_left),
              ),
              Text(
                '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}/${day.year}',
              ),
              IconButton(
                tooltip: 'Dia seguinte',
                onPressed: canGoForward ? onNext : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const Text(
            'NASA MODIS: temperatura média da superfície em 8 dias (resolução aproximada de 1 km).',
          ),
          const Text(
            'Áreas mais quentes são indícios; nuvens podem deixar partes sem dados. Não é temperatura do ar nem alerta em tempo real.',
            style: TextStyle(fontSize: 11),
          ),
        ],
      ),
    ),
  );
}
