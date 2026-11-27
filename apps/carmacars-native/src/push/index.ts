// Phone alerts. The site already queues one alert per device for every notice (its push outbox, migration 0300) and
// sends the app's through Firebase Cloud Messaging (APNs on iPhone); this registers the phone as one of those devices
// and opens the alert's page when it is tapped. Nothing here sends anything.
import { Platform } from 'react-native';
import * as Notifications from 'expo-notifications';
import { getInitialNotification, getMessaging, getToken, onMessage, onNotificationOpenedApp, onTokenRefresh } from '@react-native-firebase/messaging';
import type { Client } from '../api/client.ts';
import type { Portal } from '../shared.ts';
import { deviceLabel, getFlag, PLATFORM, setFlag } from '../native.ts';

const FLAG = 'push.token';
/** r50 hotfix 2: alerts were on when the app signed out: they come back on after the next sign-in, without asking again. */
const WAS_ON = 'push.wasOn';
/** Firebase is part of the build only when its files were there (docs/apps/native-publish.md); without it alerts stay off. */
function messaging() { try { return getMessaging(); } catch { return null; } }

export async function pushPermission(): Promise<'granted' | 'denied' | 'ask'> {
  try {
    const p = await Notifications.getPermissionsAsync();
    return p.granted ? 'granted' : p.canAskAgain ? 'ask' : 'denied';
  } catch { return 'denied'; }
}

/** Turns alerts on for this phone: the permission, the alerts channel (Android), the token, then the site keeps the device. */
export async function enablePush(api: Client, portal: Portal): Promise<{ ok: true } | { ok: false; message: string }> {
  const m = messaging();
  if (!m) return { ok: false, message: 'Alerts are not available in this build yet.' };
  const asked = await Notifications.requestPermissionsAsync({ ios: { allowAlert: true, allowBadge: true, allowSound: true } }).catch(() => null);
  if (!asked?.granted) return { ok: false, message: 'Alerts are blocked for CarmaCars. Allow notifications in the phone\'s Settings, then try again.' };
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('alerts', { name: 'CarmaCars alerts', importance: Notifications.AndroidImportance.HIGH, lightColor: '#D0111B', vibrationPattern: [0, 200, 120, 200] }).catch(() => undefined);
  }
  let token: string;
  try { token = await getToken(m); } catch { return { ok: false, message: 'This phone gave no push address. Check the connection and try again.' }; }
  const r = await api.call('me.pushOn', { body: { token, platform: PLATFORM, portal, device: deviceLabel() } });
  if (!r.ok) return { ok: false, message: r.message };
  await setFlag(FLAG, token);
  return { ok: true };
}

export async function disablePush(api: Client): Promise<void> {
  const token = await getFlag(FLAG);
  if (token) await api.call('me.pushOff', { body: { token } });
  await setFlag(FLAG, null);
  await setFlag(WAS_ON, null);
}
/** Signing out: this phone stops being one of the account's devices (called before the session ends). r50 hotfix 2 (the
 *  owner: "alerts keep turning themselves off"): a sign-out was recorded as the person turning alerts off, so the site then
 *  refused to switch them back on by itself; now it is a sign-out, and the next sign-in turns alerts back on. */
export async function forgetPushOnSignOut(api: Client): Promise<void> {
  const token = await getFlag(FLAG);
  if (token) { await api.call('me.pushOff', { body: { token, signout: true } }); await setFlag(WAS_ON, '1'); }
  await setFlag(FLAG, null);
}
export const pushIsOn = async () => (await getFlag(FLAG)) !== null;

/**
 * Listens for the app's whole life: a replaced token is sent to the site; an alert that arrives while the app is open is
 * shown as a banner; a tapped alert opens its page (data.url, a path of the site). Returns the function that stops it.
 */
export function watchPush(api: Client, portal: () => Portal, open: (url: string) => void): () => void {
  Notifications.setNotificationHandler({ handleNotification: async () => ({ shouldShowBanner: true, shouldShowList: true, shouldPlaySound: true, shouldSetBadge: false }) });
  const stops: Array<() => void> = [];
  let last = '';
  const go = (url: unknown, id: unknown) => {
    const key = `${String(id ?? '')}:${String(url ?? '')}`;
    if (typeof url !== 'string' || !url || key === last) return;
    last = key; open(url);
  };
  const taps = Notifications.addNotificationResponseReceivedListener((r) => go(r.notification.request.content.data?.url, r.notification.request.identifier));
  stops.push(() => taps.remove());
  const m = messaging();
  // signed in again after a sign-out with alerts on: back on, once the phone still allows them (never a new question)
  void (async () => {
    if ((await getFlag(WAS_ON)) !== '1' || (await getFlag(FLAG)) !== null || (await pushPermission()) !== 'granted') return;
    const r = await enablePush(api, portal());
    if (r.ok) await setFlag(WAS_ON, null);
  })().catch(() => undefined);
  if (m) {
    stops.push(onTokenRefresh(m, (token) => { void (async () => {
      const had = await getFlag(FLAG);
      if (!had || had === token) return;
      const r = await api.call('me.pushOn', { body: { token, platform: PLATFORM, portal: portal(), device: deviceLabel() } });
      if (r.ok) await setFlag(FLAG, token);
    })(); }));
    stops.push(onNotificationOpenedApp(m, (msg) => go(msg.data?.url, msg.messageId)));
    void getInitialNotification(m).then((msg) => { if (msg) go(msg.data?.url, msg.messageId); }).catch(() => undefined);
    // Android shows nothing by itself while the app is open: show the same alert through the alerts channel
    if (Platform.OS === 'android') {
      stops.push(onMessage(m, (msg) => {
        if (!msg.notification?.title) return;
        void Notifications.scheduleNotificationAsync({ content: { title: msg.notification.title, body: msg.notification.body ?? undefined, data: msg.data ?? {} }, trigger: { channelId: 'alerts' } as Notifications.NotificationTriggerInput }).catch(() => undefined);
      }));
    }
  }
  return () => { for (const stop of stops) stop(); };
}
