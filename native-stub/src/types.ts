/** Contract for a future React Native client. No native runtime is bundled. */
export type Role = 'master' | 'worker' | 'manager' | 'admin';
export type OrderStatus =
  | 'issued' | 'accepted' | 'queued' | 'rejected' | 'in_progress'
  | 'paused' | 'completed' | 'ai_review' | 'rework' | 'closed' | 'cancelled';
export type Transition = 'accept' | 'queue' | 'reject' | 'start' | 'pause'
  | 'resume' | 'close' | 'rework' | 'cancel';
export type Priority = 'emergency' | 'high' | 'normal' | 'planned';

export interface User {
  id: number;
  name: string;
  login: string;
  role: Role;
}

export interface Order {
  id: number;
  number: string;
  title: string;
  description: string;
  status: OrderStatus;
  priority: Priority;
  assignee_id: number | null;
  equipment_name: string;
  deadline: string;
  is_overdue: boolean;
  work_type: 'planned' | 'unplanned';
}

export interface Notification {
  id: number;
  title: string;
  message: string;
  kind: string;
  order_id: number | null;
  created_at: string;
  read: boolean;
}

export interface Completion {
  work_done: string;
  fault_code_id: number;
  materials: Array<{ material_id: number; quantity: number }>;
  comment?: string;
}

export interface NativeCapabilities {
  isStub: true;
  camera: 'not_implemented';
  push: 'not_implemented';
  persistentOfflineStorage: 'not_implemented';
  biometrics: 'not_implemented';
}

