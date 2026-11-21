// Location on the live map, on the phone (release 48, migration 3350). The rules are src/logic/location.ts; this file runs
// them with expo-location and expo-task-manager:
//   sync()     asks the server whether this person qualifies now (me.location) and starts or stops reading the position:
//              a watch while the app is open, or, for staff who allowed "Always", the background task (the phone shows
//              its own notice: the blue pill on iPhone, the notification on Android) that keeps reporting with the app closed
//   a fix      is sent (me.locationAct report, the bearer token of /api/m/v1) at most every 30 seconds while moving,
//              none while still; a report the server no longer keeps stops it at once and asks again
//   stopAll()  on sign-out: the watch, the task and everything remembered here
// The task is defined when this file is first imported (app/_layout.tsx), as expo-task-manager requires, so a phone that
// wakes the app in the background finds it.
import { AppState } from 'react-native';
import * as Location from 'expo-location';
import * as TaskManager from 'expo-task-manager';
import { createClient, type Client } from '@/api/client';
import { API_URL, APP_VERSION, PLATFORM, getFlag, sessionStore, setFlag } from '@/native';
import { STATE_MS, type MyLocation } from '@/shared';
import { TASK_OPTIONS, afterReport, decide, reportBody, shouldSend, wantsBackground, type Fix, type Grant, type Mode, type Perms, type Sent } from '@/logic/location';

export const LOCATION_TASK = 'carmacars-live-map';
const NOTICE = { title: 'CarmaCars is sharing your location', body: 'Only while you are on shift or on a job. Turn it off in Profile, Location on the live map.' };

let api: Client | null = null;
let state: MyLocation | null = null;
let stateAt = 0;
let mode: Mode = 'off';
let watch: Location.LocationSubscription | null = null;
let last: Sent | null = null;
let syncing: Promise<MyLocation | null> | null = null;
let sending = false;
let stopped = false;

/** The app's own client (the one that refreshes the session); a background wake with no app open makes its own. */
export function setLocationClient(c: Client): void { api = c; stopped = false; }
const client = (): Client => (api ??= createClient({ baseUrl: API_URL, fetch: (...a) => fetch(...a), session: sessionStore, appVersion: APP_VERSION, platform: PLATFORM }));

const grant = (p: { granted: boolean; canAskAgain?: boolean; status?: string }): Grant => (p.granted ? 'granted' : p.status === 'denied' || p.canAskAgain === false ? 'denied' : 'undetermined');
export async function perms(): Promise<Perms> {
  try {
    const [f, b] = await Promise.all([Location.getForegroundPermissionsAsync(), Location.getBackgroundPermissionsAsync().catch(() => ({ granted: false, status: 'undetermined' }))]);
    return { foreground: grant(f), background: grant(b) };
  } catch { return { foreground: 'undetermined', background: 'undetermined' }; }
}
/** The phone's own questions: while using the app, then (staff only) always. */
export async function ask(s: MyLocation | null): Promise<Perms> {
  try {
    const f = await Location.requestForegroundPermissionsAsync();
    if (f.granted && wantsBackground(s)) await Location.requestBackgroundPermissionsAsync().catch(() => undefined);
  } catch { /* the answer is read below */ }
  return perms();
}

const toFix = (l: Location.LocationObject): Fix => ({ lat: l.coords.latitude, lng: l.coords.longitude, accuracy: l.coords.accuracy ?? null, at: l.timestamp || Date.now(), speed: l.coords.speed ?? null });

async function onFix(f: Fix): Promise<void> {
  if (stopped || sending) return;
  // a shift or a pickup window can end while the phone keeps moving: ask the server again every 5 minutes
  if (Date.now() - stateAt > STATE_MS) { await sync(); if (mode === 'off') return; }
  if (!shouldSend(last, f)) return;
  sending = true;
  try {
    const r = await client().call('me.locationAct', { body: reportBody(f) });
    if (r.ok) last = { fix: f, at: Date.now() };
    const next = afterReport(r);
    if (next === 'stop') await stopAll();
    else if (next === 'recheck') { await apply('off'); stateAt = 0; await sync(); }
  } finally { sending = false; }
}

// the background task: the phone hands over the positions it collected
TaskManager.defineTask(LOCATION_TASK, async ({ data, error }) => {
  if (error || !data) return;
  const list = (data as { locations?: Location.LocationObject[] }).locations ?? [];
  const newest = list[list.length - 1];
  if (newest) await onFix(toFix(newest));
});

async function taskRunning(): Promise<boolean> {
  try { return await Location.hasStartedLocationUpdatesAsync(LOCATION_TASK); } catch { return false; }
}
async function apply(next: Mode): Promise<void> {
  if (next !== 'foreground' && watch) { watch.remove(); watch = null; }
  if (next !== 'background' && (await taskRunning())) await Location.stopLocationUpdatesAsync(LOCATION_TASK).catch(() => undefined);
  if (next === 'foreground' && !watch) {
    watch = await Location.watchPositionAsync({ accuracy: Location.Accuracy.High, ...TASK_OPTIONS }, (l) => void onFix(toFix(l))).catch(() => null);
    if (!watch) next = 'off';
  }
  if (next === 'background' && !(await taskRunning())) {
    try {
      await Location.startLocationUpdatesAsync(LOCATION_TASK, {
        accuracy: Location.Accuracy.High, ...TASK_OPTIONS, deferredUpdatesInterval: TASK_OPTIONS.timeInterval,
        activityType: Location.ActivityType.AutomotiveNavigation, pausesUpdatesAutomatically: true, showsBackgroundLocationIndicator: true,
        foregroundService: { notificationTitle: NOTICE.title, notificationBody: NOTICE.body, notificationColor: '#D0111B', killServiceOnDestroy: false }
      });
    } catch { next = 'off'; }
  }
  if (next === 'off') last = null;
  mode = next;
}

/**
 * Asks the server and starts or stops reading the position. `prompt`: the first time the server says this person
 * qualifies now and the phone was never asked, ask (only with the app open, so the question comes with the screen).
 */
export function sync(o: { prompt?: boolean } = {}): Promise<MyLocation | null> {
  syncing ??= (async () => {
    try {
      if (!(await sessionStore.get())) { await stopAll(); return null; }
      stopped = false;
      const r = await client().call('me.location');
      if (!r.ok) {
        if (r.code === 'auth' || r.code === 'expired') await stopAll();
        return state; // offline or busy: keep what runs now and try again later
      }
      state = r.data; stateAt = Date.now();
      let p = await perms();
      if (o.prompt && p.foreground === 'undetermined' && AppState.currentState === 'active' && decide(state, { foreground: 'granted', background: 'granted' }, true).mode !== 'off'
        && !(await getFlag('loc.asked'))) {
        await setFlag('loc.asked', '1');
        p = await ask(state);
      }
      await apply(decide(state, p, true).mode);
      return state;
    } finally { syncing = null; }
  })();
  return syncing;
}

/** Sign-out (or another account): nothing keeps reading or sending. */
export async function stopAll(): Promise<void> {
  stopped = true;
  state = null; stateAt = 0;
  await apply('off');
}

export const currentMode = (): Mode => mode;
