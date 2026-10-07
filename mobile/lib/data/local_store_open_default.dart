import 'local_store.dart';

Future<LocalStore> openLocalStore() async {
  final store = MemoryLocalStore();
  await store.open();
  return store;
}
