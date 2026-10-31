'use client';
import { useEffect, useRef, useState } from 'react';
import { SignaturePad } from '@/features/portal/SignaturePad';
import { CONSENTS, type ConsentCode } from '@/features/agreement/extra';
import { DOC_CONSENTS, type Term } from './terms';
import { esignCheckCode, esignSendCode, esignSetMobile, esignStart, esignStep } from '@/server/actions/esign';
import type { EsignContext, EsignReady, EsignView } from './types';

// The signature that holds up (migration 0154), the same on every signing page (since 0193 every signature on the site): 1. confirm it is you with a code sent
// to the phone or email on file (0186: only when Program settings require it; otherwise an optional link); 2. say you
// read the documents; 3. initial each key term (saved when the signer presses Save initials; Clear takes it back); 4.
// give the consents; 5. draw your signature. Each step is recorded with its time, IP address and device (and the place, if the signer allows it)
// and goes in the certificate of completion. The page's own Sign button is enabled once onReady gives the session.
export function EsignFlow({ ctx, terms, onReady, docsLabel = 'the agreement above' }: { ctx: EsignContext; terms: Term[]; onReady: (r: EsignReady | null) => void; docsLabel?: string }) {
  const consentText: Record<string, string> = ctx.kind === 'documents' || ctx.kind === 'cosigner' ? DOC_CONSENTS : CONSENTS;
  const [v, setV] = useState<EsignView | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [channel, setChannel] = useState<'sms' | 'email'>('sms');
  const [code, setCode] = useState('');
  const [devCode, setDevCode] = useState<string | null>(null);
  const [fixing, setFixing] = useState(false);
  const [newPhone, setNewPhone] = useState('');
  const [typed, setTyped] = useState(false);
  const [typedName, setTypedName] = useState('');
  const [sigPath, setSigPath] = useState<string | null>(null);
  const [showCode, setShowCode] = useState(false);
  // initials drawn or typed but not saved yet, by key term (saved only on Save initials)
  const [drafts, setDrafts] = useState<Record<string, string | null>>({});
  const [typedIni, setTypedIni] = useState<Record<string, string>>({});
  const geoAsked = useRef(false);

  useEffect(() => {
    let live = true;
    esignStart(ctx).then((r) => { if (!live) return; if (r.ok) { setV(r.data); setChannel(r.data.default_channel ?? r.data.channels[0]?.channel ?? 'email'); } else setErr(r.message); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    if (v?.ready && sigPath) onReady({ session: v.id, method: 'drawn', drawnPath: sigPath });
    else if (v?.ready && typed && typedName.trim()) onReady({ session: v.id, method: 'typed', typedName: typedName.trim() });
    else onReady(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [v?.ready, sigPath, typed, typedName]);
  // the place, once identity is confirmed (or the code is not asked for), if the signer's device allows it (never in the way)
  const codeOk = !!v && (v.verified || !v.code_required);
  useEffect(() => {
    if (!v || !codeOk || geoAsked.current || typeof navigator === 'undefined' || !navigator.geolocation) return;
    geoAsked.current = true;
    navigator.geolocation.getCurrentPosition((p) => { void esignStep(ctx, v.id, { kind: 'geolocation', lat: p.coords.latitude, lng: p.coords.longitude, accuracy: p.coords.accuracy }); }, () => undefined, { timeout: 8000, maximumAge: 600000 });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [codeOk]);

  // one step at a time, in the order given: each answer is the session after that step (a later step never sees an
  // earlier answer arrive after it)
  const queue = useRef<Promise<unknown>>(Promise.resolve());
  const canFix = ctx.kind === 'renter' || ctx.kind === 'amendment' || ctx.kind === 'in_person';
  const run = (f: () => Promise<{ ok: true; data: EsignView & { devCode?: string; path?: string } } | { ok: false; message: string }>) => {
    const p = queue.current.then(async () => {
      setBusy(true); setErr(null);
      try { const r = await f(); if (r.ok) { setV(r.data); if (r.data.devCode) setDevCode(r.data.devCode); return r.data; } setErr(r.message); return null; } finally { setBusy(false); }
    });
    queue.current = p.catch(() => undefined);
    return p;
  };
  if (!v) return <p className="small muted" role="status" data-testid="esign-loading">{err ?? 'Preparing your signature…'}</p>;
  const want = terms.filter((t) => v.required_initials.includes(t.code));
  const initialsDone = want.every((t) => v.initials.includes(t.code));
  const consentsDone = v.required_consents.every((c) => v.consents.includes(c));
  // step 1 is shown when the code is required, already confirmed, or the signer chose to verify by code
  const askCode = v.code_required || v.verified || showCode;
  const n0 = askCode ? 1 : 0;
  const saveInitials = (code: string, step: { png?: string; typed?: string }) => run(() => esignStep(ctx, v.id, { kind: 'initial', code, ...step }))
    .then((d) => { if (d) { setDrafts((x) => ({ ...x, [code]: null })); setTypedIni((x) => ({ ...x, [code]: '' })); } });
  // clearing a saved initial removes it from the session: the signer initials again (and signs again after)
  const clearInitials = (code: string) => run(() => esignStep(ctx, v.id, { kind: 'initial_clear', code }))
    .then((d) => { if (d) { setDrafts((x) => ({ ...x, [code]: null })); setSigPath(null); } });
  return (
    <div className="es-flow" data-testid="esign-flow" data-ready={v.ready ? 'true' : 'false'} data-complete={v.ready && (sigPath || (typed && typedName.trim())) ? 'true' : 'false'}>
      {!askCode && <p className="small" data-testid="esign-code-optional">
        <button type="button" className="link" onClick={() => setShowCode(true)} data-testid="esign-code-open">Verify by code (optional)</button></p>}
      {askCode && <section className="es-step" data-state={v.verified ? 'done' : 'open'} aria-labelledby="es-1">
        <div className="es-step__head"><h3 className="d4" id="es-1">1. Confirm it is you{v.code_required ? '' : ' (optional)'}</h3>{v.verified && <span className="badge" data-testid="esign-verified">Confirmed</span>}</div>
        {!v.verified && <>
          <p className="small">We send a 6-digit code to {v.signer_name.split(' ')[0]}&apos;s phone or email on file. It shows the signature is yours.</p>
          {v.channels.length === 0 && !canFix ? <p className="alert alert--error" role="alert"><span>No mobile number or email is on file for {v.signer_name}. Ask CarmaCars to add one.</span></p> : <>
            <fieldset className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}><legend className="vh">Where to send the code</legend>
              {v.channels.map((c) => <label key={c.channel} className="check"><input type="radio" name="es-channel" checked={channel === c.channel} onChange={() => setChannel(c.channel)} data-testid={`esign-channel-${c.channel}`} />
                <span>{c.channel === 'sms' ? 'Text' : 'Email'} to {c.to}{c.channel === 'email' && v.email_held ? ' (our emails are delayed right now)' : ''}</span></label>)}
            </fieldset>
            <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'end' }}>
              <button className="btn btn--ghost" type="button" disabled={busy} onClick={() => run(() => esignSendCode(ctx, v.id, channel))} data-testid="esign-send">{v.code_sent_to ? 'Send a new code' : 'Send the code'}</button>
              {v.code_sent_to && <>
                <label className="field" style={{ margin: 0 }}><span className="label">Code sent to {v.code_sent_to}</span>
                  <input className="input es-code" inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} data-testid="esign-code" /></label>
                <button className="btn btn--primary" type="button" disabled={busy || code.length !== 6} onClick={() => run(() => esignCheckCode(ctx, v.id, code))} data-testid="esign-confirm">Confirm</button>
              </>}
            </div>
            {devCode && <p className="xs muted" data-testid="esign-dev-code">Test code (local only): {devCode}</p>}
            {canFix && (!fixing ? <p className="small"><button type="button" className="link" onClick={() => setFixing(true)} data-testid="esign-fix-phone">{v.channels.some((c) => c.channel === 'sms') ? 'Wrong phone number? Change it' : 'Add a mobile number'}</button></p>
              : <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'end' }}>
                <label className="field" style={{ margin: 0 }}><span className="label">The right mobile number</span>
                  <input className="input" type="tel" inputMode="tel" autoComplete="tel" value={newPhone} onChange={(e) => setNewPhone(e.target.value)} data-testid="esign-new-phone" /></label>
                <button className="btn btn--ghost" type="button" disabled={busy || newPhone.replace(/\D/g, '').length < 10}
                  onClick={() => run(() => esignSetMobile(ctx, v.id, newPhone)).then((d) => { if (d) { setFixing(false); setNewPhone(''); setCode(''); setChannel('sms'); } })} data-testid="esign-save-phone">Save the number</button>
                <button className="btn btn--ghost" type="button" onClick={() => setFixing(false)}>Cancel</button></div>)}
          </>}
        </>}
      </section>}
      {v.licence && <p className="xs muted" data-testid="esign-licence">Licence on file: {[v.licence.licence_front && 'front', v.licence.licence_back && 'back', v.licence.selfie && 'selfie'].filter(Boolean).join(', ') || 'none yet'}{v.licence.verified ? ', verified' : ''}.</p>}

      {codeOk && <section className="es-step" data-state={v.viewed ? 'done' : 'open'} aria-labelledby="es-2">
        <h3 className="d4" id="es-2">{n0 + 1}. Read</h3>
        <label className="check"><input type="checkbox" checked={v.viewed} disabled={v.viewed || busy} onChange={() => run(() => esignStep(ctx, v.id, { kind: 'viewed' }))} data-testid="esign-viewed" />
          <span>I have read {docsLabel}.</span></label>
      </section>}

      {codeOk && v.viewed && want.length > 0 && <section className="es-step" data-state={initialsDone ? 'done' : 'open'} aria-labelledby="es-3">
        <div className="es-step__head"><h3 className="d4" id="es-3">{n0 + 2}. Initial the key terms</h3><span className="small muted">{v.initials.filter((c) => want.some((t) => t.code === c)).length} of {want.length}</span></div>
        {want.map((t) => <div key={t.code} className="es-term" data-testid={`esign-term-${t.code}`}>
          <p className="small"><b>{t.title}.</b> {t.text}</p>
          {v.initials.includes(t.code) ? <div className="row" style={{ gap: 'var(--s-2)', alignItems: 'center' }}><p className="fd-line is-ok" style={{ margin: 0 }}><span aria-hidden="true">✓</span> Initialled</p>
              <button className="btn btn--quiet btn--sm" type="button" disabled={busy} onClick={() => void clearInitials(t.code)} aria-label={`Clear your initials for ${t.title} and initial again`} data-testid={`esign-clear-initials-${t.code}`}>Clear</button></div>
            : typed ? <div className="row" style={{ gap: 'var(--s-2)' }}><input className="input" aria-label={`Your initials for ${t.title}`} maxLength={5} id={`es-ti-${t.code}`}
                value={typedIni[t.code] ?? ''} onChange={(e) => setTypedIni((x) => ({ ...x, [t.code]: e.target.value }))} data-testid={`esign-typed-initials-${t.code}`} />
              <button className="btn btn--ghost btn--sm" type="button" disabled={busy || !(typedIni[t.code] ?? '').trim()} onClick={() => void saveInitials(t.code, { typed: (typedIni[t.code] ?? '').trim() })} data-testid={`esign-save-initials-${t.code}`}>Save initials</button>
              {(typedIni[t.code] ?? '') && <button className="btn btn--quiet btn--sm" type="button" onClick={() => setTypedIni((x) => ({ ...x, [t.code]: '' }))}>Clear</button>}</div>
            : <div className="stack" style={{ gap: 'var(--s-1)' }}>
                <SignaturePad id={`es-in-${t.code}`} small minPoints={4} testId={`initials-${t.code}`} label={`Initials box for ${t.title}: draw your initials`}
                  onChange={(png) => setDrafts((x) => ({ ...x, [t.code]: png }))} />
                <div><button className="btn btn--ghost btn--sm" type="button" disabled={busy || !drafts[t.code]} onClick={() => { const png = drafts[t.code]; if (png) void saveInitials(t.code, { png }); }}
                  data-testid={`esign-save-initials-${t.code}`}>Save initials</button></div></div>}
        </div>)}
      </section>}

      {codeOk && v.viewed && initialsDone && <section className="es-step" data-state={consentsDone ? 'done' : 'open'} aria-labelledby="es-4">
        <h3 className="d4" id="es-4">{n0 + (want.length > 0 ? 3 : 2)}. Consent</h3>
        {v.required_consents.map((c) => <label key={c} className="check"><input type="checkbox" checked={v.consents.includes(c)} disabled={v.consents.includes(c) || busy}
          onChange={() => run(() => esignStep(ctx, v.id, { kind: 'consent', code: c as ConsentCode }))} data-testid={`esign-consent-${c}`} /><span>{consentText[c] ?? c}</span></label>)}
      </section>}

      {codeOk && v.viewed && initialsDone && consentsDone && <section className="es-step" data-state={v.signature ? 'done' : 'open'} aria-labelledby="es-5">
        <div className="es-step__head"><h3 className="d4" id="es-5">{n0 + (want.length > 0 ? 4 : 3)}. Sign</h3>
          {v.typed_fallback_allowed && <button type="button" className="btn btn--quiet btn--sm" onClick={() => setTyped(!typed)} data-testid="esign-typed-toggle">{typed ? 'Draw instead' : 'I cannot draw a signature'}</button>}</div>
        {typed ? <label className="field"><span className="label">Type your full legal name: {v.signer_name}</span>
            <input className="input sigpad__typed" value={typedName} onChange={(e) => setTypedName(e.target.value)} onBlur={() => { if (typedName.trim()) void run(() => esignStep(ctx, v.id, { kind: 'signature', typed: typedName.trim() })); }} /></label>
          : <SignaturePad id="es-sig" onChange={(png) => { if (!png) { setSigPath(null); return; } void run(() => esignStep(ctx, v.id, { kind: 'signature', png })).then((d) => setSigPath((d as { path?: string } | null)?.path ?? null)); }} />}
      </section>}
      {err && <p className="alert alert--error" role="alert" data-testid="esign-error"><span>{err}</span></p>}
      <p className="xs muted">Your electronic signature and initials are binding. We record the time, IP address and device of each step, and the place if your device shares it, in a certificate attached to your signed copy.</p>
    </div>
  );
}
