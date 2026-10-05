import type { NativeCapabilities } from './types';

export const nativeCapabilities: NativeCapabilities = {
  isStub: true,
  camera: 'not_implemented',
  push: 'not_implemented',
  persistentOfflineStorage: 'not_implemented',
  biometrics: 'not_implemented',
};

export async function capturePhoto(): Promise<never> {
  throw new Error('Заглушка: камера будет подключена в React Native клиенте.');
}

export async function registerPushToken(): Promise<{ isStub: true; registered: false }> {
  return { isStub: true, registered: false };
}

/** Explicitly a simulation: data is lost when the process stops. */
export class OfflineQueueStub {
  readonly isStub = true;
  private pending: Array<{ id: string; createdAt: string; payload: unknown }> = [];

  enqueue(payload: unknown): string {
    const id = `local-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    this.pending.push({ id, createdAt: new Date().toISOString(), payload });
    return id;
  }

  inspect(): ReadonlyArray<{ id: string; createdAt: string; payload: unknown }> {
    return this.pending.map(item => ({ ...item }));
  }

  remove(id: string): void {
    this.pending = this.pending.filter(item => item.id !== id);
  }
}

