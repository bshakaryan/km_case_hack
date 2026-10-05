import { NaryadApi } from './api';
import { nativeCapabilities, registerPushToken } from './native';

/** Call manually from a future React Native screen; never runs on import. */
export async function loadWorkerScreen(serverUrl: string, login: string, pin: string) {
  const api = new NaryadApi(serverUrl);
  const user = await api.login(login, pin);
  const [orders, notifications, push] = await Promise.all([
    api.getOrders(), api.getNotifications(), registerPushToken(),
  ]);
  return { user, orders, notifications, push, capabilities: nativeCapabilities };
}

