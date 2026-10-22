'use client';
import Link from 'next/link';
import { useCallback, useEffect, useRef, useState, type FocusEvent } from 'react';
import { visitorId } from '@/features/live/beacon';
import { captureNote, cleanFields, type CaptureFields, type CaptureForm, type CaptureReply } from './fields';

// Contact capture (migration 0090), the browser's side: when a field loses focus and is valid, what the person typed
// (name, email, phone, nothing else) is sent to /api/capture after a short pause, once per change. Never blocks the
// form; a failure is silent and the form works as before.
export function useCapture(form: CaptureForm, ctx?: () => { ref?: string | null; draftToken?: string | null }) {
  const last = useRef('');
  const sent = useRef<{ f: CaptureFields; ref: string } | null>(null);
  const timer = useRef<number | undefined>(undefined);
  const ctxRef = useRef(ctx);
  useEffect(() => { ctxRef.current = ctx; });
  const [reply, setReply] = useState<CaptureReply | null>(null);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const capture = useCallback((raw: { name?: unknown; email?: unknown; phone?: unknown }) => {
    const f: CaptureFields = cleanFields(raw);
    if (!f.name && !f.email && !f.phone) return;
    const c = ctxRef.current?.() ?? {};
    const key = JSON.stringify([f, c.ref ?? '']);
    if (key === last.current) return;
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => {
      last.current = key;
      sent.current = { f, ref: c.ref ?? '' };
      let vid: string | undefined;
      try { vid = visitorId(); } catch { vid = undefined; }
      fetch('/api/capture', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin', keepalive: true,
        body: JSON.stringify({ form, ...f, ref: c.ref ?? null, draftToken: c.draftToken ?? null, vid, page: location.pathname }) })
        .then((r) => (r.ok ? (r.json() as Promise<CaptureReply>) : null))
        .then((r) => { if (r) setReply(r); })
        .catch(() => { last.current = ''; });
    }, 600);
  }, [form]);
  /** The form got its draft after the last save: the same values again, now with the draft (never new values). */
  const relink = useCallback(() => {
    const prev = sent.current;
    const ref = ctxRef.current?.()?.ref ?? '';
    if (prev && ref && prev.ref !== ref) capture(prev.f);
  }, [capture]);
  /** For an uncontrolled form: onBlur on the <form> reads its name, email and phone inputs. */
  const onFormBlur = useCallback((e: FocusEvent<HTMLFormElement>, names: { name?: string | string[]; email?: string; phone?: string } = { name: 'name', email: 'email', phone: 'phone' }) => {
    const fd = new FormData(e.currentTarget);
    const get = (k?: string) => (k ? String(fd.get(k) ?? '') : '');
    const name = Array.isArray(names.name) ? names.name.map(get).filter(Boolean).join(' ') : get(names.name);
    capture({ name, email: get(names.email), phone: get(names.phone) });
  }, [capture]);
  return { capture, relink, onFormBlur, reply };
}

/** The line under the form after a save ("You have an account: we sent you a sign-in link."). */
export function CaptureNote({ reply, next }: { reply: CaptureReply | null; next?: string }) {
  const n = captureNote(reply);
  if (!n) return null;
  return (
    <p className={`small ${n.tone === 'ok' ? 'muted' : ''}`} role="status" data-testid="capture-note">
      {n.text}{n.signIn && <> <Link prefetch={false} className="link" href={`/sign-in${next ? `?next=${encodeURIComponent(next)}` : ''}`}>Sign in</Link></>}
    </p>
  );
}
