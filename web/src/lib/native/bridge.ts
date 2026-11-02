// The store app's plugins, called from the site (migration 0390). The Capacitor shell injects its native bridge into
// every page it opens (window.Capacitor: nativePromise, nativeCallback and the PluginHeaders of the plugins built into
// the app, apps/carmacars/package.json), so the site needs no Capacitor package of its own: a plugin method is
// nativePromise(plugin, method, options) and an event is the plugin's addListener callback. In a browser every helper
// here is a no-op that answers null or false. Client only; no imports.

interface CapBridge {
  isNativePlatform?: () => boolean;
  getPlatform?: () => string;
  PluginHeaders?: Array<{ name: string; methods?: Array<{ name: string }> }>;
  nativePromise?: <T>(plugin: string, method: string, options?: Record<string, unknown>) => Promise<T>;
  nativeCallback?: (plugin: string, method: string, options: Record<string, unknown>, cb: (data: unknown, err?: unknown) => void) => string;
}

function bridge(): CapBridge | null {
  if (typeof window === 'undefined') return null;
  const c = (window as unknown as { Capacitor?: CapBridge }).Capacitor;
  return c && typeof c.isNativePlatform === 'function' && c.isNativePlatform() && typeof c.nativePromise === 'function' ? c : null;
}

/** True inside the store app (the native bridge is there), false in a browser. */
export function inApp(): boolean { return bridge() !== null; }

export function platform(): 'ios' | 'android' | null {
  const p = bridge()?.getPlatform?.();
  return p === 'ios' || p === 'android' ? p : null;
}

/** The plugin is built into this version of the app. */
export function has(plugin: string): boolean {
  return !!bridge()?.PluginHeaders?.some((h) => h.name === plugin);
}

/** One plugin method; rejects when the app has no such plugin (an older app version) or the call fails. */
export function call<T = unknown>(plugin: string, method: string, options: Record<string, unknown> = {}): Promise<T> {
  const b = bridge();
  if (!b || !has(plugin)) return Promise.reject(new Error(`${plugin} is not available`));
  return b.nativePromise!<T>(plugin, method, options);
}

/** A plugin event; returns the function that stops listening. */
export function listen<T = unknown>(plugin: string, event: string, cb: (data: T) => void): () => void {
  const b = bridge();
  if (!b || !has(plugin) || typeof b.nativeCallback !== 'function') return () => undefined;
  let id: string | null = null;
  try {
    id = b.nativeCallback(plugin, 'addListener', { eventName: event }, (data, err) => { if (!err) cb(data as T); });
  } catch { return () => undefined; }
  return () => { if (id) void b.nativePromise!(plugin, 'removeListener', { eventName: event, callbackId: id }).catch(() => undefined); };
}

/** A short tap of the phone's vibration motor: light for a touch, success or error for the end of something. */
export function haptic(kind: 'light' | 'success' | 'warning' | 'error' = 'light'): void {
  if (!has('Haptics')) return;
  const p = kind === 'light' ? call('Haptics', 'impact', { style: 'LIGHT' }) : call('Haptics', 'notification', { type: kind.toUpperCase() });
  void p.catch(() => undefined);
}

/** The phone's share sheet (in the app) or the browser's (navigator.share); false when neither could share. */
export async function share(d: { title?: string; text?: string; url: string }): Promise<boolean> {
  if (has('Share')) {
    try { await call('Share', 'share', { title: d.title, text: d.text, url: d.url, dialogTitle: d.title }); return true; } catch { return false; }
  }
  const n = typeof navigator !== 'undefined' ? (navigator as Navigator & { share?: (x: ShareData) => Promise<void> }) : null;
  if (n?.share) { try { await n.share(d); return true; } catch { return false; } }
  return false;
}

/** The app's own small store (Keychain-backed UserDefaults on iOS, SharedPreferences on Android). */
export async function prefGet(key: string): Promise<string | null> {
  if (!has('Preferences')) return null;
  try { return (await call<{ value: string | null }>('Preferences', 'get', { key })).value ?? null; } catch { return null; }
}
export async function prefSet(key: string, value: string | null): Promise<void> {
  if (!has('Preferences')) return;
  await (value === null ? call('Preferences', 'remove', { key }) : call('Preferences', 'set', { key, value })).catch(() => undefined);
}

/** Face ID, Touch ID or the fingerprint: what this phone has (null: none set up, or an app without the plugin). */
export async function biometry(): Promise<{ kind: 'face' | 'fingerprint' | 'other'; label: string } | null> {
  if (!has('BiometricAuthNative')) return null;
  try {
    const r = await call<{ isAvailable: boolean; biometryType: number }>('BiometricAuthNative', 'checkBiometry');
    if (!r.isAvailable) return null;
    // @aparajita/capacitor-biometric-auth BiometryType: 1 touchId, 2 faceId, 3 fingerprint, 4 face (Android), 5 iris
    const ios = platform() === 'ios';
    if (r.biometryType === 2) return { kind: 'face', label: 'Face ID' };
    if (r.biometryType === 1) return { kind: 'fingerprint', label: 'Touch ID' };
    if (r.biometryType === 3) return { kind: 'fingerprint', label: 'fingerprint' };
    if (r.biometryType === 4) return { kind: 'face', label: ios ? 'Face ID' : 'face unlock' };
    return { kind: 'other', label: 'biometrics' };
  } catch { return null; }
}

/** Ask for Face ID or the fingerprint (the phone's passcode as the fallback). True when the person passed. */
export async function authenticate(reason: string): Promise<boolean> {
  if (!has('BiometricAuthNative')) return false;
  try {
    await call('BiometricAuthNative', 'internalAuthenticate', {
      reason, cancelTitle: 'Cancel', allowDeviceCredential: true, iosFallbackTitle: 'Use passcode',
      androidTitle: 'Unlock CarmaCars', androidSubtitle: reason, androidConfirmationRequired: false
    });
    return true;
  } catch { return false; }
}
