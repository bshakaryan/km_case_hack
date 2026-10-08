import 'dart:async';

import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/models.dart';

// Acknowledged completion may precede its queued formal review. Never resubmit.
Future<WorkOrder> waitForAiReview(
  NaryadApi api,
  int orderId, {
  Duration timeout = const Duration(seconds: 45),
  Duration interval = const Duration(milliseconds: 500),
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < timeout) {
    final order = await api.order(orderId).timeout(timeout - elapsed.elapsed);
    if (order.status == 'ai_review') return order;
    final status = order.aiReviewJob?['status'];
    if (status == 'failed' || status == 'superseded') {
      throw StateError(
        'Formal review did not complete: $status. The report remains saved.',
      );
    }
    if (order.status != 'completed') {
      throw StateError(
        'Unexpected order state while awaiting formal review: ${order.status}',
      );
    }
    final remaining = timeout - elapsed.elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(interval < remaining ? interval : remaining);
    }
  }
  throw TimeoutException('Awaiting queued formal review', timeout);
}
