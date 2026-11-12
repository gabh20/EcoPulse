import 'package:flutter_test/flutter_test.dart';
import 'package:ecopulse/models/report.dart';

void main() {
  test('relatos expirados deixam de ser ativos mesmo offline', () {
    final report = Report({
      'id': '1',
      'type': 'HEAT',
      'status': 'ACTIVE',
      'description': '',
      'latitude': 0,
      'longitude': 0,
      'observed_at': '2020-01-01T00:00:00Z',
      'expires_at': '2020-01-01T03:00:00Z',
    });
    expect(report.active, isFalse);
    expect(report.point.latitude, 0);
  });
}
