import type { Completion, Notification, Order, Transition, User } from './types';

/** HTTP boundary reusable from React Native. The caller owns secure token storage. */
export class NaryadApi {
  private token: string | null = null;
  private readonly baseUrl: string;

  constructor(serverUrl: string, private readonly request: typeof fetch = fetch) {
    this.baseUrl = `${serverUrl.replace(/\/$/, '')}/api`;
  }

  setToken(token: string | null): void {
    this.token = token;
  }

  private async json<T>(path: string, options: RequestInit = {}): Promise<T> {
    const response = await this.request(`${this.baseUrl}${path}`, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
        ...options.headers,
      },
    });
    if (!response.ok) {
      const error = await response.json().catch(() => null) as { detail?: unknown } | null;
      throw new Error(`HTTP ${response.status}: ${JSON.stringify(error?.detail ?? response.statusText)}`);
    }
    return response.json() as Promise<T>;
  }

  async login(login: string, pin: string): Promise<User> {
    const result = await this.json<{ token: string; user: User }>('/auth/login', {
      method: 'POST', body: JSON.stringify({ login, pin }),
    });
    this.token = result.token;
    return result.user;
  }

  getOrders(): Promise<Order[]> {
    return this.json<Order[]>('/orders');
  }

  transition(orderId: number, action: Transition, reason?: string): Promise<Order> {
    return this.json<Order>(`/orders/${orderId}/transition`, {
      method: 'POST', body: JSON.stringify({ action, reason }),
    });
  }

  complete(orderId: number, completion: Completion): Promise<Order> {
    return this.json<Order>(`/orders/${orderId}/complete`, {
      method: 'POST', body: JSON.stringify(completion),
    });
  }

  getNotifications(): Promise<Notification[]> {
    return this.json<Notification[]>('/notifications');
  }

  /** Native camera must supply a validated React Native FormData file separately. */
  async uploadPhoto(orderId: number, formData: FormData): Promise<unknown> {
    const response = await this.request(`${this.baseUrl}/orders/${orderId}/photos`, {
      method: 'POST',
      headers: this.token ? { Authorization: `Bearer ${this.token}` } : {},
      body: formData,
    });
    if (!response.ok) throw new Error(`Photo upload failed: HTTP ${response.status}`);
    return response.json();
  }
}

