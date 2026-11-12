import 'package:flutter_test/flutter_test.dart';
import 'package:ecopulse/models/report.dart';
import 'package:ecopulse/services/api.dart';
import 'package:ecopulse/services/app_state.dart';
import 'package:ecopulse/services/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ResolveApi extends Api {
  final bool fail;
  ResolveApi({this.fail = false}) : super('http://localhost');
  @override
  Future<dynamic> request(
    String method,
    String route, {
    Map<String, dynamic>? body,
  }) async {
    if (fail) throw ApiError(503, 'Sem conexão');
    return {'state': 'RESOLVED'};
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test('ocorrência resolvida não aparece ativa antes do prazo original', () {
    final report = Report({
      'id': 'resolved',
      'type': 'HEAT',
      'status': 'RESOLVED',
      'observed_at': DateTime.now().toUtc().toIso8601String(),
      'expires_at': DateTime.now()
          .add(const Duration(hours: 3))
          .toUtc()
          .toIso8601String(),
    });
    expect(report.active, isFalse);
  });

  for (final fail in [false, true]) {
    test(
      fail
          ? 'falha ao encerrar preserva relato ativo'
          : 'encerrar atualiza mapa, histórico e cache local',
      () async {
        final store = await LocalStore.open(databasePath: inMemoryDatabasePath);
        final state = AppState(store, false, 'http://localhost');
        state.userId = 'author';
        state.api = ResolveApi(fail: fail);
        final report = {
          'id': 'one',
          'type': 'HEAT',
          'status': 'ACTIVE',
          'observed_at': DateTime.now().toUtc().toIso8601String(),
          'expires_at': DateTime.now()
              .add(const Duration(hours: 3))
              .toUtc()
              .toIso8601String(),
        };
        state.reports = [Report(report)];
        await store.enqueue('author', report);
        await store.state('one', 'SYNCED');
        if (fail) {
          await expectLater(
            state.resolveReport('one'),
            throwsA(isA<ApiError>()),
          );
          expect(state.reports.single.id, 'one');
          expect((await store.pending('author')).single['state'], 'SYNCED');
        } else {
          await state.resolveReport('one');
          expect(state.reports, isEmpty);
          expect((await store.pending('author')).single['state'], 'RESOLVED');
          expect(await store.cached('user:author:reports'), isEmpty);
          expect(await store.cached('user:author:resolved'), ['one']);
          expect(state.myReportsCount, 0);
        }
        expect(state.resolvingReports, isEmpty);
        state.dispose();
        await store.db.close();
      },
    );
  }
}
