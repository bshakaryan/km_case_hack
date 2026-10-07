import 'dart:async';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  const limit = Duration(minutes: 12);
  try {
    // SDK requestData's timeout only warns; bound the entire host collector.
    await integrationDriver(timeout: limit).timeout(limit);
  } on TimeoutException {
    stderr.writeln(
      'SDK result collection timed out. Native PASS alone is insufficient; '
      'keep the test app installed and inspect the driver connection.',
    );
    exit(1);
  }
}
