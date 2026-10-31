'use client';
import dynamic from 'next/dynamic';
import { useCallback, useEffect, useRef, useState } from 'react';
import { visitorId } from '@/features/live/beacon';
import { draftPhone, gateOn, passValid, passValue, PASS_COOKIE, PASS_DAYS, type GateKind, type GateRules } from './rules';

// The phone number box (migration 0280), the browser's side. ask(kind, go) runs go at once when the box is off, when
// this device already gave a number (the cc_pg cookie of this visitor id, 90 days, or a number in the request form's
// saved draft) or when a signed-in renter has a verified mobile; otherwise it opens the box and runs go once a number is
// given. Nothing here runs for a page view: the server is asked only after a tap, and the box's code loads only then.
const PhoneGateDialog = dynamic(() => import('./PhoneGateDialog').then((m) => m.PhoneGateDialog), { ssr: false });
const PHONE_KEY = 'cc_pg_phone';
const EVENT = 'cc:phone-gate';

const readCookie = (n: string) => document.cookie.split('; ').find((c) => c.startsWith(n + '='))?.split('=').slice(1).join('=');
function vid(): string | null { try { return visitorId(); } catch { return null; } }

/** This device gave a number (cookie of this visitor id, or the request form's saved number). */
export function hasPass(): boolean {
  try {
    if (passValid(readCookie(PASS_COOKIE), vid(), Date.now())) return true;
    const p = draftPhone(localStorage.getItem('cc.request.v2'));
    if (p) { remember(p); return true; }
  } catch { /* cookies or storage blocked */ }
  return false;
}
/** The number given on this device (for the request form), or null. */
export function gatePhone(): string | null {
  try { return hasPass() ? localStorage.getItem(PHONE_KEY) : null; } catch { return null; }
}
function remember(phone: string | null) {
  const v = vid();
  if (!v) return;
  document.cookie = `${PASS_COOKIE}=${passValue(v, Date.now())}; path=/; max-age=${PASS_DAYS * 86400}; samesite=lax${location.protocol === 'https:' ? '; secure' : ''}`;
  try { if (phone) localStorage.setItem(PHONE_KEY, phone); } catch { /* private mode */ }
  window.dispatchEvent(new Event(EVENT));
}
function count(e: 'shown' | 'closed', gate: GateKind) {
  const body = JSON.stringify({ e, gate, vid: vid() });
  try {
    if (navigator.sendBeacon?.('/api/phone-gate', new Blob([body], { type: 'application/json' }))) return;
  } catch { /* fall back */ }
  fetch('/api/phone-gate', { method: 'POST', headers: { 'content-type': 'application/json' }, body, keepalive: true, credentials: 'same-origin' }).catch(() => undefined);
}

/** True once this device gave a number (false while rendering on the server and before the first effect: no mismatch). */
export function useGatePassed(): boolean {
  const [ok, setOk] = useState(false);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setOk(hasPass());
    const on = () => setOk(hasPass());
    window.addEventListener(EVENT, on);
    return () => window.removeEventListener(EVENT, on);
  }, []);
  return ok;
}

export function usePhoneGate(rules: GateRules | null | undefined) {
  const [open, setOpen] = useState<{ kind: GateKind; go: () => void } | null>(null);
  const opener = useRef<HTMLElement | null>(null);
  const busy = useRef(false);
  const ask = useCallback(async (kind: GateKind, go: () => void) => {
    if (!gateOn(rules, kind) || hasPass()) { go(); return; }
    if (busy.current) return;
    busy.current = true;
    opener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    try {
      const { phoneGateStatus } = await import('@/server/actions/phone-gate');
      const st = await phoneGateStatus().catch(() => null);
      if (st?.ok && st.data.pass) { remember(st.data.phone); go(); return; }
      setOpen({ kind, go });
      count('shown', kind);
    } finally { busy.current = false; }
  }, [rules]);
  const back = () => { const o = opener.current; if (o && document.contains(o)) o.focus({ preventScroll: true }); };
  const dialog = open && rules ? (
    <PhoneGateDialog kind={open.kind} rules={rules}
      onDone={(phone) => { const go = open.go; remember(phone); setOpen(null); back(); go(); }}
      onClose={() => { count('closed', open.kind); setOpen(null); back(); }} />
  ) : null;
  return { ask, dialog };
}
