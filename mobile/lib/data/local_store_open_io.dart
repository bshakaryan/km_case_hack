import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'local_store_io.dart';

Future<LocalStore> openLocalStore() async {
  try {
    final store = SqfliteLocalStore();
    await store.open();
    return store;
  } catch (error) {
    debugPrint(
      '[naryad.store] sqflite unavailable; using in-memory store: $error',
    );
    final store = MemoryLocalStore();
    await store.open();
    return store;
  }
}
