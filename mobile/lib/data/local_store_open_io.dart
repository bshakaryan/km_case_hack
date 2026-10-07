import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'local_store_io.dart';

Future<LocalStore> openLocalStore() async {
  try {
    final store = SqfliteLocalStore();
    await store.open();
    return store;
  } catch (error) {
    debugPrint('[naryad.store] persistent storage unavailable: $error');
    rethrow;
  }
}
