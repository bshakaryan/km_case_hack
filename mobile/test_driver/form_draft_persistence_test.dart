import 'dart:async';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  const limit = Duration(minutes: 8);
  try {
    await integrationDriver(timeout: limit).timeout(limit);
  } on TimeoutException {
    stderr.writeln(
      'SDK result collection timed out; native PASS alone is insufficient. Keep the app installed to inspect the driver connection.',
    );
    exit(1);
  }
}
