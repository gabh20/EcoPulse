import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

const reportLabels = {
  'FLOOD': 'Alagamento',
  'BLOCKED_ROAD': 'Via obstruída',
  'SMOKE': 'Fumaça',
  'AIR_QUALITY': 'Qualidade do ar',
  'HEAT': 'Calor excessivo',
};

Color reportColor(String type) => switch (type) {
  'FLOOD' => Colors.blue,
  'BLOCKED_ROAD' => Colors.red,
  'SMOKE' => Colors.deepPurple,
  'AIR_QUALITY' => Colors.brown,
  _ => Colors.orange,
};

IconData reportIcon(String type) => switch (type) {
  'FLOOD' => Icons.water,
  'BLOCKED_ROAD' => Icons.block,
  'SMOKE' => Icons.cloud,
  'AIR_QUALITY' => Icons.air,
  _ => Icons.thermostat,
};

class Report {
  final Map<String, dynamic> data;
  Report(this.data);
  String get id => data['id'] as String;
  String get type => data['type'] as String;
  String get description => data['description'] as String? ?? '';
  LatLng get point => LatLng(
    (data['latitude'] as num).toDouble(),
    (data['longitude'] as num).toDouble(),
  );
  DateTime get observedAt => DateTime.parse(data['observed_at'] as String);
  DateTime get expiresAt => DateTime.parse(data['expires_at'] as String);
  bool get active =>
      data['status'] == 'ACTIVE' && expiresAt.isAfter(DateTime.now());
}
