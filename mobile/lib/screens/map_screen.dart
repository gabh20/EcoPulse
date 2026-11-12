import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/report.dart';
import '../services/app_state.dart';
import 'pending_screen.dart';
import 'report_screen.dart';
import 'heat_island_layer.dart';
import 'temperature_layer.dart';

class MapScreen extends StatefulWidget {
  final AppState state;
  const MapScreen({super.key, required this.state});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final controller = MapController();
  final filters = reportLabels.keys.toSet();
  bool heatLayer = false;
  bool heatIslandsEnabled = false;
  late DateTime heatIslandDay = HeatIslandLayer.latestDay();
  bool temperatureEnabled = false;
  Timer? _temperatureDebounce;
  Timer? _temperatureRefresh;
  bool ready = false;
  bool _centered = false;
  @override
  void initState() {
    super.initState();
    widget.state.addListener(showAlert);
    widget.state.addListener(_centerOnFirstLocation);
    _temperatureRefresh = Timer.periodic(const Duration(minutes: 1), (_) {
      if (temperatureEnabled) loadTemperature();
    });
  }

  void showAlert() {
    final alert = widget.state.alert;
    if (alert == null || !mounted) return;
    widget.state.alert = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(alert)));
      }
    });
  }

  void _centerOnFirstLocation() {
    final location = widget.state.location;
    if (_centered || !ready || location == null || !mounted) return;
    _centered = true;
    controller.move(location, 15);
  }

  String _formatTime(Object? value) {
    final time = DateTime.tryParse(value as String? ?? '')?.toLocal();
    if (time == null) return '—';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.day)}/${two(time.month)} às ${two(time.hour)}:${two(time.minute)}';
  }

  @override
  void dispose() {
    _temperatureDebounce?.cancel();
    _temperatureRefresh?.cancel();
    widget.state.cancelTemperatureLoad();
    widget.state.removeListener(showAlert);
    widget.state.removeListener(_centerOnFirstLocation);
    controller.dispose();
    super.dispose();
  }

  void loadTemperature({bool force = false}) {
    if (!temperatureEnabled || !mounted) return;
    final point = ready
        ? controller.camera.center
        : widget.state.location ?? const LatLng(-23.5505, -46.6333);
    unawaited(
      widget.state.loadTemperature(
        point.latitude,
        point.longitude,
        force: force,
      ),
    );
  }

  void toggleTemperature(bool enabled) {
    setState(() {
      temperatureEnabled = enabled;
      if (enabled) heatIslandsEnabled = false;
    });
    _temperatureDebounce?.cancel();
    if (enabled) {
      loadTemperature();
    } else {
      widget.state.cancelTemperatureLoad();
    }
  }

  void toggleHeatIslands(bool enabled) {
    setState(() {
      heatIslandsEnabled = enabled;
      if (enabled) temperatureEnabled = false;
    });
    if (enabled) widget.state.cancelTemperatureLoad();
  }

  void showEnvironmentDetails(Map<String, dynamic> environment) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Dados ambientais',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text('Fonte: Open-Meteo e CAMS.'),
              const Text('Valores estimados por modelos regionais.'),
              const SizedBox(height: 12),
              Text(
                'Temperatura atualizada em ${_formatTime(environment['weather_time'])}',
              ),
              Text(
                'Qualidade do ar atualizada em ${_formatTime(environment['air_time'])}',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void details(Report report) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reportLabels[report.type]!,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    report.description.isEmpty
                        ? 'Sem descrição adicional.'
                        : report.description,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Observado: ${report.observedAt.toLocal().toString().substring(0, 16)}',
                  ),
                  Text(
                    'Validade: ${report.expiresAt.toLocal().toString().substring(0, 16)}',
                  ),
                  Text(
                    'Precisão do GPS: ${(report.data['accuracy_meters'] as num).round()} m',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Fonte: relato colaborativo. A área colorida indica influência aproximada, não o contorno real do fenômeno.',
                  ),
                  if (report.data['user_id'] == widget.state.userId &&
                      report.active) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(
                        widget.state.resolvingReports.contains(report.id)
                            ? 'Encerrando…'
                            : 'Marcar como resolvido',
                      ),
                      onPressed:
                          widget.state.resolvingReports.contains(report.id)
                          ? null
                          : () async {
                              try {
                                await widget.state.resolveReport(report.id);
                                if (context.mounted) Navigator.pop(context);
                                if (mounted) {
                                  ScaffoldMessenger.of(
                                    this.context,
                                  ).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Ocorrência marcada como resolvida.',
                                      ),
                                    ),
                                  );
                                }
                              } catch (error) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Não foi possível encerrar. Confira a conexão e tente novamente. $error',
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> center() async {
    await widget.state.updateLocation();
    if (mounted && ready && widget.state.location != null) {
      controller.move(widget.state.location!, 15);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final visible = state.reports
        .where((r) => filters.contains(r.type) && r.active)
        .toList();
    final environment = state.environment;
    return Scaffold(
      appBar: AppBar(
        title: const Text('EcoPulse'),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: state.refreshing ? null : state.refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Sair',
            onPressed: state.logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: state.online
                ? const Color(0xFFE4F2E9)
                : const Color(0xFFFFF0D9),
            padding: const EdgeInsets.all(10),
            child: Text(
              state.online
                  ? 'Conectado · ocorrências em até 3 km'
                  : 'Sem acesso ao servidor · exibindo dados locais',
            ),
          ),
          if (state.message != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(child: Text(state.message!)),
                  IconButton(
                    onPressed: () {
                      state.message = null;
                      setState(() {});
                    },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          if (environment != null)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.eco_outlined),
              title: Text(
                '${environment['temperature_celsius'] ?? '—'} °C  ·  AQI ${environment['european_aqi'] ?? '—'}',
              ),
              subtitle: Text(
                state.staleEnvironment
                    ? 'Últimos dados salvos'
                    : 'Condições ambientais estimadas',
              ),
              trailing: IconButton(
                tooltip: 'Detalhes dos dados ambientais',
                onPressed: () => showEnvironmentDetails(environment),
                icon: const Icon(Icons.info_outline),
              ),
            )
          else if (state.online)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('Dados ambientais indisponíveis.'),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                ...reportLabels.entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: FilterChip(
                      label: Text(entry.value),
                      selected: filters.contains(entry.key),
                      onSelected: (value) {
                        setState(() {
                          value
                              ? filters.add(entry.key)
                              : filters.remove(entry.key);
                        });
                      },
                    ),
                  ),
                ),
                FilterChip(
                  label: const Text('Relatos de calor'),
                  selected: heatLayer,
                  onSelected: (value) {
                    setState(() {
                      heatLayer = value;
                    });
                  },
                ),
                FilterChip(
                  key: const Key('heat-islands-toggle'),
                  avatar: const Icon(Icons.wb_sunny_outlined, size: 18),
                  label: const Text('Ilhas de calor'),
                  selected: heatIslandsEnabled,
                  onSelected: toggleHeatIslands,
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: FilterChip(
                    key: const Key('temperature-toggle'),
                    avatar: const Icon(Icons.thermostat, size: 18),
                    label: const Text('Temperatura estimada'),
                    selected: temperatureEnabled,
                    onSelected: toggleTemperature,
                  ),
                ),
              ],
            ),
          ),
          if (heatLayer)
            const Padding(
              padding: EdgeInsets.all(4),
              child: Text(
                'Sobreposição de relatos de calor · indicação colaborativa',
                style: TextStyle(fontSize: 12),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: controller,
                  options: MapOptions(
                    initialCenter:
                        state.location ?? const LatLng(-23.5505, -46.6333),
                    initialZoom: 14,
                    onMapReady: () {
                      ready = true;
                      _centered = state.location != null;
                      if (temperatureEnabled) loadTemperature();
                    },
                    onPositionChanged: (camera, hasGesture) {
                      if (temperatureEnabled) {
                        _temperatureDebounce?.cancel();
                        _temperatureDebounce = Timer(
                          const Duration(milliseconds: 800),
                          loadTemperature,
                        );
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'br.edu.ecopulse',
                      maxZoom: 19,
                    ),
                    if (heatIslandsEnabled) HeatIslandLayer(day: heatIslandDay),
                    if (temperatureEnabled && state.temperatureLayer != null)
                      TemperatureMapLayer(data: state.temperatureLayer!),
                    CircleLayer(
                      circles: visible
                          .map(
                            (report) => CircleMarker(
                              point: report.point,
                              radius: heatLayer && report.type == 'HEAT'
                                  ? 350
                                  : 100,
                              useRadiusInMeter: true,
                              color: reportColor(report.type).withValues(
                                alpha: heatLayer && report.type == 'HEAT'
                                    ? 0.16
                                    : 0.09,
                              ),
                              borderColor: reportColor(
                                report.type,
                              ).withValues(alpha: 0.3),
                              borderStrokeWidth: 1,
                            ),
                          )
                          .toList(),
                    ),
                    MarkerLayer(
                      markers: [
                        if (state.location != null)
                          Marker(
                            point: state.location!,
                            width: 24,
                            height: 24,
                            child: const Icon(
                              Icons.my_location,
                              color: Colors.teal,
                            ),
                          ),
                        ...visible.map(
                          (report) => Marker(
                            point: report.point,
                            width: 44,
                            height: 44,
                            child: IconButton(
                              tooltip: reportLabels[report.type],
                              icon: Icon(
                                reportIcon(report.type),
                                color: reportColor(report.type),
                              ),
                              onPressed: () => details(report),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Align(
                      alignment: Alignment.bottomLeft,
                      child: ColoredBox(
                        color: Colors.white,
                        child: Padding(
                          padding: EdgeInsets.all(4),
                          child: Text(
                            '© OpenStreetMap contributors · openstreetmap.org/copyright',
                            style: TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'center',
                    tooltip: 'Minha localização',
                    onPressed: center,
                    child: const Icon(Icons.my_location),
                  ),
                ),
                if (temperatureEnabled)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 26,
                    child: TemperatureLegend(
                      data: state.temperatureLayer,
                      loading: state.temperatureLoading,
                      stale: state.temperatureStale,
                      error: state.temperatureError,
                      onRefresh: () => loadTemperature(force: true),
                    ),
                  ),
                if (heatIslandsEnabled)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 26,
                    child: HeatIslandLegend(
                      day: heatIslandDay,
                      canGoForward: heatIslandDay.isBefore(
                        HeatIslandLayer.latestDay(),
                      ),
                      onPrevious: () => setState(() {
                        heatIslandDay = heatIslandDay.subtract(
                          HeatIslandLayer.period,
                        );
                      }),
                      onNext: () => setState(() {
                        heatIslandDay = heatIslandDay.add(
                          HeatIslandLayer.period,
                        );
                      }),
                    ),
                  ),
                if (state.refreshing || state.syncing)
                  const Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PendingScreen(state: state),
                        ),
                      ),
                      icon: const Icon(Icons.sync),
                      label: Text('Meus relatos (${state.myReportsCount})'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ReportScreen(state: state),
                        ),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Relatar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
