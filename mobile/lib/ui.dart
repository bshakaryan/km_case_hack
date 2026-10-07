import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'data/models.dart';

const navy = Color(0xff163e70);
const ink = Color(0xff172a3d);
const muted = Color(0xff566779);
const danger = Color(0xffb42332);
const line = Color(0xffdce3eb);
const statuses = <String, String>{
  'issued': 'Выдан',
  'accepted': 'Принят · ожидает начала',
  'queued': 'Ожидает очереди',
  'rejected': 'Отклонён',
  'in_progress': 'В работе',
  'paused': 'Приостановлен',
  'completed': 'Исполнено',
  'ai_review': 'Проверка ИИ',
  'rework': 'На доработку',
  'closed': 'Закрыт',
  'cancelled': 'Отменён',
};
const priorities = <String, String>{
  'emergency': 'Аварийный',
  'high': 'Высокий',
  'normal': 'Обычный',
  'planned': 'Плановый',
};
bool terminal(WorkOrder o) => {'closed', 'cancelled'}.contains(o.status);
bool _timeReady = false;
DateTime plantTime(DateTime value) {
  if (!_timeReady) {
    tzdata.initializeTimeZones();
    _timeReady = true;
  }
  return tz.TZDateTime.from(value.toUtc(), tz.getLocation('Asia/Almaty'));
}

String dateLabel(DateTime value) =>
    DateFormat('dd.MM · HH:mm').format(plantTime(value));
String clockLabel(DateTime value) =>
    DateFormat('HH:mm:ss').format(plantTime(value));
String numeric(Object? value, {int digits = 0}) =>
    value is num ? value.toStringAsFixed(digits) : '—';

ThemeData appTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: navy,
      primary: navy,
      surface: Colors.white,
      error: danger,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xfff4f6f9),
    textTheme: base.textTheme.copyWith(
      headlineMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: ink,
        height: 1.15,
      ),
      titleLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      titleMedium: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      bodyLarge: const TextStyle(fontSize: 17, color: ink, height: 1.4),
      bodyMedium: const TextStyle(fontSize: 16, color: ink, height: 1.35),
      bodySmall: const TextStyle(fontSize: 14, color: muted, height: 1.35),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: ink,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 54),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 52),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        side: const BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: line),
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: Color(0xffe6edf7),
      height: 78,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    dividerTheme: const DividerThemeData(color: line, thickness: 1),
  );
}

class Tag extends StatelessWidget {
  const Tag(this.label, {this.color = navy, super.key});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {this.action, super.key});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        ?action,
      ],
    ),
  );
}

class InfoPanel extends StatelessWidget {
  const InfoPanel(
    this.text, {
    this.icon = Icons.info_outline,
    this.color = muted,
    this.action,
    super.key,
  });
  final String text;
  final IconData icon;
  final Color color;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: .2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: TextStyle(color: color, fontSize: 15)),
              ?action,
            ],
          ),
        ),
      ],
    ),
  );
}

class OrderCard extends StatelessWidget {
  const OrderCard({
    required this.order,
    required this.onTap,
    this.nextAction,
    super.key,
  });
  final WorkOrder order;
  final VoidCallback onTap;
  final String? nextAction;
  @override
  Widget build(BuildContext context) {
    final o = order;
    final urgent = o.priority == 'emergency' && !terminal(o);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        o.number,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 20, color: muted),
                  ],
                ),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    Tag(statuses[o.status] ?? o.status),
                    if (o.data['queue_position'] is num)
                      Tag(
                        (o.data['queue_position'] as num).toInt() == 1
                            ? 'Следующий к началу'
                            : 'Очередь · место ${o.data['queue_position']}',
                        color: navy,
                      ),
                    if (o.pendingSync)
                      const Tag(
                        'Ожидает синхронизации',
                        color: Color(0xFF8C5A00),
                      ),
                    if (urgent || o.priority == 'high')
                      Tag(
                        priorities[o.priority]!,
                        color: urgent ? danger : const Color(0xff8a5100),
                      ),
                    if (o.isOverdue) const Tag('Срок истёк', color: danger),
                  ],
                ),
                const SizedBox(height: 12),
                Text(o.title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 5),
                Text(
                  '${o.equipmentName} · ${o.areaName}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.schedule_outlined,
                      size: 18,
                      color: o.isOverdue ? danger : muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'До ${dateLabel(o.deadline)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: o.isOverdue ? danger : muted,
                        ),
                      ),
                    ),
                  ],
                ),
                if (o.assigneeName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      o.assigneeName,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (nextAction != null) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onTap,
                      child: Text(nextAction!),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
