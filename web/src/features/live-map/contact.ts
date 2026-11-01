'use client';
import { useSyncExternalStore } from 'react';

// "Show contact" (Release 26): one switch for the Visitors page (the map, Live now and History). Hidden by default,
// remembered on this device (localStorage when it works, else this visit only: a private window, blocked storage).
// While it is off, the page asks the server for no phone or email at all.
export const CONTACT_KEY = 'carmacars.live-map.contact';
let memo: boolean | null = null;
const subs = new Set<() => void>();
export function readContact(): boolean {
  if (memo !== null) return memo;
  try { return localStorage.getItem(CONTACT_KEY) === '1'; } catch { return false; }
}
export function writeContact(on: boolean) {
  memo = on;
  try { localStorage.setItem(CONTACT_KEY, on ? '1' : '0'); } catch { /* this visit only */ }
  for (const f of subs) f();
}
function subscribe(f: () => void) { subs.add(f); return () => { subs.delete(f); }; }
/** The switch's state, the same in every component that asks (false while the server draws the page). */
export function useContact(): boolean {
  return useSyncExternalStore(subscribe, readContact, () => false);
}
