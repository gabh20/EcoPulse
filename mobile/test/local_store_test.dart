import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ecopulse/services/local_store.dart';
import 'package:ecopulse/services/app_state.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test('relato pendente preserva UUID e pertence apenas ao autor', () async {
    final store = await LocalStore.open(databasePath: inMemoryDatabasePath);
    await store.enqueue('maria', {'id': 'stable-id', 'type': 'FLOOD'});
    expect((await store.pending('maria')).single['id'], 'stable-id');
    expect(await store.pending('joao'), isEmpty);
    await store.state('stable-id', 'QUEUED');
    expect((await store.pending('maria')).single['state'], 'QUEUED');
    expect(await store.deviceId(), await store.deviceId());
    await store.db.close();
  });
  test('cache mantém os últimos dados e separa contas', () async {
    final store = await LocalStore.open(databasePath: inMemoryDatabasePath);
    await store.saveCache('user:maria:environment', {
      'temperature_celsius': 28,
    });
    expect(
      (await store.cached('user:maria:environment'))['temperature_celsius'],
      28,
    );
    expect(await store.cached('user:joao:environment'), isNull);
    await store.db.close();
  });
  test('contador inclui relato processado', () async {
    final store = await LocalStore.open(databasePath: inMemoryDatabasePath);
    await store.enqueue('maria', {'id': 'one', 'type': 'FLOOD'});
    await store.state('one', 'SYNCED');
    final state = AppState(store, false, 'http://localhost')..userId = 'maria';
    state.pending = await store.pending('maria');
    expect(state.myReportsCount, 1);
    state.dispose();
    await store.db.close();
  });
}
