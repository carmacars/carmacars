// The phone's own parts, each behind one small function: the keychain, Face ID and fingerprint, the camera, the location,
// passkeys and the in-app browser. Screens call these; nothing else imports the native modules.
import { Platform } from 'react-native';
import Constants from 'expo-constants';
import * as SecureStore from 'expo-secure-store';
import * as LocalAuthentication from 'expo-local-authentication';
import * as ImagePicker from 'expo-image-picker';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import * as Location from 'expo-location';
import * as WebBrowser from 'expo-web-browser';
import * as Device from 'expo-device';
import { Passkey } from 'react-native-passkey';
import type { MobileSession, PasskeyOptions } from './shared.ts';
import type { SessionStore, UploadFile } from './api/client.ts';
import { cancelled, createRequest, getRequest, none } from './logic/passkey.ts';

const extra = (Constants.expoConfig?.extra ?? {}) as { apiUrl?: string; siteHosts?: string[] };
export const API_URL = (extra.apiUrl ?? 'https://carmacars.ca').replace(/\/$/, '');
export const SITE_HOSTS = extra.siteHosts ?? ['carmacars.ca', 'www.carmacars.ca'];
export const APP_VERSION = Constants.expoConfig?.version ?? '1.0.0';
export const PLATFORM: 'ios' | 'android' = Platform.OS === 'ios' ? 'ios' : 'android';
export const deviceLabel = () => `CarmaCars app on ${Device.modelName ?? (PLATFORM === 'ios' ? 'iPhone' : 'Android')}`.slice(0, 60);

// ---------------------------------------------------------------- the keychain
// The session lives in the Keychain (iPhone) or the Keystore (Android), on this phone only: never in a backup.
const KEY = 'cc.session.v1';
const OPTS: SecureStore.SecureStoreOptions = { keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY };
let cached: MobileSession | null | undefined;
const listeners = new Set<(s: MobileSession | null) => void>();
export const sessionStore: SessionStore & { subscribe(fn: (s: MobileSession | null) => void): () => void } = {
  async get() {
    if (cached !== undefined) return cached;
    try { const raw = await SecureStore.getItemAsync(KEY, OPTS); cached = raw ? (JSON.parse(raw) as MobileSession) : null; } catch { cached = null; }
    return cached;
  },
  async set(s) {
    cached = s;
    try { if (s) await SecureStore.setItemAsync(KEY, JSON.stringify(s), OPTS); else await SecureStore.deleteItemAsync(KEY, OPTS); } catch { /* the session then lasts until the app closes */ }
    for (const fn of listeners) fn(s);
  },
  subscribe(fn) { listeners.add(fn); return () => { listeners.delete(fn); }; }
};
export async function getFlag(name: string): Promise<string | null> { try { return await SecureStore.getItemAsync(`cc.${name}`, OPTS); } catch { return null; } }
export async function setFlag(name: string, value: string | null): Promise<void> {
  try { if (value === null) await SecureStore.deleteItemAsync(`cc.${name}`, OPTS); else await SecureStore.setItemAsync(`cc.${name}`, value, OPTS); } catch { /* not kept */ }
}

// ---------------------------------------------------------------- Face ID, fingerprint, passcode
export async function canLock(): Promise<boolean> {
  try { return (await LocalAuthentication.hasHardwareAsync()) && (await LocalAuthentication.isEnrolledAsync()); } catch { return false; }
}
/** Asks for Face ID, the fingerprint or, failing those, the phone's passcode. */
export async function unlockWithDevice(reason = 'Unlock CarmaCars'): Promise<boolean> {
  try { return (await LocalAuthentication.authenticateAsync({ promptMessage: reason, cancelLabel: 'Cancel', disableDeviceFallback: false })).success; } catch { return false; }
}

// ---------------------------------------------------------------- the camera
export type Shot = UploadFile & { takenAt: string; width: number; height: number };
export type ShotResult = { ok: true; shot: Shot } | { ok: false; reason: 'cancelled' | 'denied' | 'failed' };
/** One photo with the phone's camera, made a JPEG no wider than 2,000 px (a licence stays readable, an upload stays small). */
export async function takePhoto(o: { front?: boolean; library?: boolean } = {}): Promise<ShotResult> {
  try {
    const perm = o.library ? await ImagePicker.requestMediaLibraryPermissionsAsync() : await ImagePicker.requestCameraPermissionsAsync();
    if (!perm.granted) return { ok: false, reason: 'denied' };
    const opts: ImagePicker.ImagePickerOptions = { mediaTypes: ['images'], quality: 0.9, exif: false, cameraType: o.front ? ImagePicker.CameraType.front : ImagePicker.CameraType.back };
    const r = o.library ? await ImagePicker.launchImageLibraryAsync(opts) : await ImagePicker.launchCameraAsync(opts);
    const a = r.canceled ? null : r.assets[0];
    if (!a) return { ok: false, reason: 'cancelled' };
    const longest = Math.max(a.width, a.height);
    const ctx = ImageManipulator.manipulate(a.uri);
    if (longest > 2000) ctx.resize(a.width >= a.height ? { width: 2000 } : { height: 2000 });
    const out = await (await ctx.renderAsync()).saveAsync({ compress: 0.82, format: SaveFormat.JPEG });
    return { ok: true, shot: { uri: out.uri, name: `photo-${Date.now()}.jpg`, type: 'image/jpeg', takenAt: new Date().toISOString(), width: out.width, height: out.height } };
  } catch { return { ok: false, reason: 'failed' }; }
}
export const photoProblem = (r: Exclude<ShotResult, { ok: true }>): string | null =>
  r.reason === 'cancelled' ? null : r.reason === 'denied' ? 'CarmaCars cannot use the camera. Allow it in the phone\'s Settings, then try again.' : 'The photo could not be taken. Try again.';
/** How many bytes a local file is (a presigned upload must say its size first). */
export async function fileBlob(uri: string): Promise<Blob> { return (await fetch(uri)).blob(); }

// ---------------------------------------------------------------- where the phone is
export interface Fix { lat: number; lng: number; accuracy: number; located_at: string }
export async function locate(): Promise<Fix | null> {
  try {
    const p = await Location.requestForegroundPermissionsAsync();
    if (!p.granted) return null;
    const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
    return { lat: Math.round(pos.coords.latitude * 1e6) / 1e6, lng: Math.round(pos.coords.longitude * 1e6) / 1e6, accuracy: Math.round(pos.coords.accuracy ?? 0), located_at: new Date(pos.timestamp).toISOString() };
  } catch { return null; }
}

// ---------------------------------------------------------------- passkeys
export const passkeysSupported = (): boolean => { try { return Passkey.isSupported(); } catch { return false; } };
export type PasskeyAnswer<T> = { ok: true; credential: T } | { ok: false; reason: 'cancelled' | 'none' | 'failed' };
const why = (e: unknown) => (cancelled(e) ? 'cancelled' as const : none(e) ? 'none' as const : 'failed' as const);
export async function makePasskey(o: PasskeyOptions): Promise<PasskeyAnswer<{ id: string; response: { clientDataJSON: string; attestationObject: string } }>> {
  try { const r = await Passkey.create(createRequest(o)); return { ok: true, credential: { id: r.id, response: { clientDataJSON: r.response.clientDataJSON, attestationObject: r.response.attestationObject } } }; }
  catch (e) { return { ok: false, reason: why(e) }; }
}
export async function usePasskey(o: PasskeyOptions): Promise<PasskeyAnswer<{ id: string; response: { clientDataJSON: string; authenticatorData: string; signature: string } }>> {
  try {
    const r = await Passkey.get(getRequest(o));
    return { ok: true, credential: { id: r.id, response: { clientDataJSON: r.response.clientDataJSON, authenticatorData: r.response.authenticatorData, signature: r.response.signature } } };
  } catch (e) { return { ok: false, reason: why(e) }; }
}

// ---------------------------------------------------------------- the in-app browser
/** A page of the site that the app has no screen for (the Admin portal's long tail, guides, terms): Safari or Chrome inside the app. */
export async function openSite(path: string, siteUrl: string = API_URL): Promise<void> {
  const url = /^https:\/\//.test(path) ? path : `${siteUrl}${path.startsWith('/') ? path : `/${path}`}`;
  await WebBrowser.openBrowserAsync(url, { toolbarColor: '#0A0A0A', controlsColor: '#FFFFFF', dismissButtonStyle: 'close', presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET }).catch(() => undefined);
}
