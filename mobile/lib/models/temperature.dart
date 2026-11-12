import 'package:flutter/material.dart';

const temperatureColors = [
  Color(0xFF2879CF),
  Color(0xFFF3D54E),
  Color(0xFFF58B35),
  Color(0xFFC82F28),
];
const temperatureStops = [0.0, 0.5, 0.75, 1.0];

Color temperatureColor(double celsius) {
  final value = ((celsius - 10) / 30).clamp(0.0, 1.0);
  for (var i = 1; i < temperatureStops.length; i++) {
    if (value <= temperatureStops[i]) {
      final fraction =
          (value - temperatureStops[i - 1]) /
          (temperatureStops[i] - temperatureStops[i - 1]);
      return Color.lerp(
        temperatureColors[i - 1],
        temperatureColors[i],
        fraction,
      )!;
    }
  }
  return temperatureColors.last;
}

bool temperatureCovers(
  Map<String, dynamic> data,
  double latitude,
  double longitude,
) {
  final anchor = data['anchor'] as Map;
  return latitude >= (anchor['south'] as num) &&
      latitude < (anchor['north'] as num) &&
      longitude >= (anchor['west'] as num) &&
      longitude < (anchor['east'] as num);
}

bool temperatureRecent(Map<String, dynamic> data, Duration maxAge) {
  final time = DateTime.tryParse(data['fetched_at'] as String? ?? '');
  if (time == null) return false;
  final age = DateTime.now().toUtc().difference(time);
  return !age.isNegative && age <= maxAge;
}
