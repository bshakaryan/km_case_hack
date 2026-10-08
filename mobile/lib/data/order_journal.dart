import 'models.dart';

class OrderJournalQuery {
  const OrderJournalQuery({
    this.scope = 'all',
    this.focus = 'all',
    this.sort = 'newest',
    this.search = '',
    this.areaId,
    this.equipmentId,
    this.assigneeId,
    this.brigadeId,
    this.priority,
    this.status,
    this.fromDate,
    this.toDate,
  });

  final String scope, focus, sort, search;
  final int? areaId, equipmentId, assigneeId, brigadeId;
  final String? priority, status, fromDate, toDate;

  Map<String, String> parameters({int limit = 100, String? cursor}) => {
    'limit': '$limit',
    'scope': scope,
    'focus': focus,
    'sort': sort,
    if (search.trim().isNotEmpty) 'search': search.trim(),
    if (areaId != null) 'area_id': '$areaId',
    if (equipmentId != null) 'equipment_id': '$equipmentId',
    if (assigneeId != null) 'assignee_id': '$assigneeId',
    if (brigadeId != null) 'brigade_id': '$brigadeId',
    'priority': ?priority,
    'status': ?status,
    if (fromDate?.isNotEmpty == true) 'from_date': fromDate!,
    if (toDate?.isNotEmpty == true) 'to_date': toDate!,
    'cursor': ?cursor,
  };
}

class OrderPage {
  const OrderPage({
    required this.items,
    required this.nextCursor,
    required this.total,
  });
  factory OrderPage.fromJson(Json data) {
    if (data['items'] is! List ||
        !data.containsKey('next_cursor') ||
        (data['next_cursor'] != null && data['next_cursor'] is! String) ||
        data['next_cursor'] == '' ||
        data['total'] is! int ||
        (data['total'] as int) < 0) {
      throw const FormatException('Некорректная страница журнала.');
    }
    final items = (data['items'] as List).map((row) {
      if (row is! Map ||
          row['id'] is! int ||
          (row['id'] as int) < 1 ||
          row['number'] is! String ||
          row['title'] is! String ||
          row['status'] is! String ||
          row['priority'] is! String ||
          row['work_type'] is! String ||
          row['normal_hours'] is! num ||
          row['deadline'] is! String ||
          DateTime.tryParse(row['deadline'] as String) == null) {
        throw const FormatException('Некорректный наряд в странице журнала.');
      }
      return WorkOrder.fromJson(Map<String, dynamic>.from(row));
    }).toList();
    return OrderPage(
      items: List.unmodifiable(items),
      nextCursor: data['next_cursor'] as String?,
      total: data['total'] as int,
    );
  }

  final List<WorkOrder> items;
  final String? nextCursor;
  final int total;
}

class EquipmentDetails {
  const EquipmentDetails({
    required this.id,
    required this.name,
    required this.inventoryNumber,
    required this.areaId,
    required this.areaName,
    required this.type,
    required this.criticality,
  });

  factory EquipmentDetails.fromJson(Json data) {
    if (data['id'] is! int ||
        (data['id'] as int) < 1 ||
        data['area_id'] is! int ||
        [
          'name',
          'inventory_number',
          'area_name',
          'type',
          'criticality',
        ].any((field) => data[field] is! String)) {
      throw const FormatException('Некорректная карточка оборудования.');
    }
    return EquipmentDetails(
      id: data['id'] as int,
      name: data['name'] as String,
      inventoryNumber: data['inventory_number'] as String,
      areaId: data['area_id'] as int,
      areaName: data['area_name'] as String,
      type: data['type'] as String,
      criticality: data['criticality'] as String,
    );
  }

  final int id, areaId;
  final String name, inventoryNumber, areaName, type, criticality;
}
