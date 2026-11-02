'use client';
import { useEffect, useState } from 'react';
import { authenticate, biometry, haptic, prefGet, prefSet } from '@/lib/native/bridge';
import { UNLOCK_KEY } from './unlock';

// Face ID or fingerprint unlock (migration 0390), on the profile in the store app only: once on, the app asks for it
// when it opens and when it comes back after 5 minutes (AppShell). Hidden in a browser and on a phone without
// Face ID, Touch ID or a fingerprint set up. Turning it on asks once, so the person knows it works.
export function AppUnlockCard({ className = 'pt-card' }: { className?: string }) {
  const [bio, setBio] = useState<{ label: string } | null>(null);
  const [on, setOn] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    (async () => {
      const b = await biometry();
      const v = await prefGet(UNLOCK_KEY);
      if (live) { setBio(b); setOn(v === '1'); }
    })();
    return () => { live = false; };
  }, []);
  if (!bio) return null;

  const toggle = async (next: boolean) => {
    setBusy(true); setMsg(null);
    try {
      if (next && !(await authenticate(`Use ${bio.label} to open CarmaCars`))) { setMsg(`${bio.label} did not confirm. Unlock stays off.`); return; }
      await prefSet(UNLOCK_KEY, next ? '1' : null);
      setOn(next); haptic(next ? 'success' : 'light');
      setMsg(next ? `On. CarmaCars asks for ${bio.label} when it opens.` : 'Off.');
    } finally { setBusy(false); }
  };

  return (
    <section className={`${className} pa`} aria-labelledby="au-title" data-testid="app-unlock-card">
      <div className="pa__head"><h2 className="d4" id="au-title">App lock</h2></div>
      <div className="pa__grid">
      <label className="option pa__opt">
        <input type="checkbox" role="switch" checked={on} disabled={busy} onChange={(e) => void toggle(e.target.checked)} data-testid="app-unlock-switch" />
        <span className="option__title">Unlock with {bio.label}</span>
        <span className="option__body">Asked when the app opens and after 5 minutes away. On this phone only.</span>
      </label>
      </div>
      {msg && <p className="small muted" role="status">{msg}</p>}
    </section>
  );
}
