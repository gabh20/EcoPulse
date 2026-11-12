import 'package:flutter_test/flutter_test.dart';
import 'package:ecopulse/screens/heat_island_layer.dart';

void main() {
  test('camada usa composto MODIS de oito dias concluído', () {
    final day = HeatIslandLayer.latestDay(DateTime.utc(2026, 11, 11));
    expect(day, DateTime.utc(2026, 11, 1));
    expect(
      HeatIslandLayer.tileUrl(day),
      contains('MODIS_Terra_L3_Land_Surface_Temp_8Day_Day'),
    );
    expect(HeatIslandLayer.tileUrl(day), contains('/2026-11-01/'));
  });
}
