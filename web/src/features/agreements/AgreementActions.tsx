'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { agreementFill, agreementOverride, agreementRegenerate, agreementResend, disputePackBuild, disputePackSubmit } from '@/server/actions/agreements';

export interface Missing { key: string; label: string; where: string; required: boolean; driver_id?: string }

// What the agreements print blank, filled in place (migration 0154). Each missing value is one input; Save writes them
// all and the agreements follow (a corrected copy, or a version to sign when it is material).
const INPUT: Record<string, { type: string; hint?: string }> = {
  date_of_birth: { type: 'date' }, licence_expiry: { type: 'date' }, policy_expiry: { type: 'date' }, mobile: { type: 'tel' }, adjuster_phone: { type: 'tel' }
};
export function MissingFields({ booking, missing, refresh, isAdmin, overrides }: { booking: string; missing: Missing[]; refresh: string[]; isAdmin: boolean; overrides: Array<{ at: string; reason: string; by: string | null }> }) {
  const router = useRouter();
  const [vals, setVals] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [reason, setReason] = useState('');
  const [pending, start] = useTransition();
  const fillable = missing.filter((m) => m.where !== 'settings');
  if (!missing.length) return <p className="small fd-line is-ok" data-testid="agreement-complete"><span aria-hidden="true">✓</span> Every field of both agreements has its value.</p>;
  const inputs = (m: Missing): Array<{ name: string; label: string; type: string }> => {
    const leaf = m.key.split('.').pop()!;
    if (leaf === 'address') return [['address_line1', 'Street'], ['city', 'City'], ['province', 'Province'], ['postal_code', 'Postal code']].map(([n, l]) => ({ name: `${m.key}.${n}`, label: `${m.label}: ${l}`, type: 'text' }));
    return [{ name: m.key, label: m.label, type: INPUT[leaf]?.type ?? 'text' }];
  };
  const payload = () => {
    const p: Record<string, unknown> = {}; const drivers: Record<string, Record<string, string>> = {};
    for (const [k, v] of Object.entries(vals)) {
      if (!v.trim()) continue;
      const parts = k.split('.');
      if (parts[0] === 'drivers') { const d = (drivers[parts[1]!] ??= { driver_id: parts[1]! }); d[parts[3] ?? parts[2]!] = v; continue; }
      const group = parts[0]!; const field = parts.length === 3 ? parts[2]! : parts[1]!;
      (p[group] ??= {}) as Record<string, string>;
      (p[group] as Record<string, string>)[field] = v;
    }
    if (Object.keys(drivers).length) p.drivers = Object.values(drivers);
    return p;
  };
  const required = missing.filter((m) => m.required);
  return (
    <div className="stack" data-testid="agreement-missing">
      <p className="small"><b>{required.length ? `${required.length} field${required.length === 1 ? '' : 's'} a claim needs ${required.length === 1 ? 'is' : 'are'} blank` : 'Recommended'}</b>: the agreements print these blank until they are filled.{required.length ? ' Check-out stops until they are, unless an Admin overrides.' : ''}</p>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); start(async () => { const r = await agreementFill(booking, payload(), refresh); setMsg(r.ok ? { ok: true, text: 'Saved. The agreements follow in a moment.' } : { ok: false, text: r.message }); if (r.ok) { setVals({}); router.refresh(); } }); }}>
        <div className="grid-2" style={{ display: 'grid', gap: 'var(--s-2)', gridTemplateColumns: 'repeat(auto-fit, minmax(14rem, 1fr))' }}>
          {fillable.flatMap(inputs).map((f) => (
            <label key={f.name} className="field" style={{ margin: 0 }}><span className="label">{f.label}{missing.find((m) => f.name.startsWith(m.key))?.required ? ' *' : ''}</span>
              <input className="input" type={f.type} value={vals[f.name] ?? ''} onChange={(e) => setVals((v) => ({ ...v, [f.name]: e.target.value }))} data-testid={`fill-${f.name.replace(/[^a-z0-9]+/gi, '-')}`} /></label>
          ))}
        </div>
        {missing.some((m) => m.where === 'settings') && <p className="xs muted">CarmaCars&apos; HST number: Program settings, Company HST number.</p>}
        {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
        {fillable.length > 0 && <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="agreement-fill">{pending ? 'Saving' : 'Save the missing fields'}</button>}
      </form>
      {isAdmin && required.length > 0 && <form className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'end' }} onSubmit={(e) => { e.preventDefault(); start(async () => { const r = await agreementOverride(booking, reason, refresh); setMsg(r.ok ? { ok: true, text: 'Check-out may go ahead without these fields. The reason is on the booking\'s history.' } : { ok: false, text: r.message }); if (r.ok) router.refresh(); }); }}>
        <label className="field" style={{ margin: 0, flex: '1 1 16rem' }}><span className="label">Admin: let the check-out go ahead without them, because</span>
          <input className="input" value={reason} minLength={5} onChange={(e) => setReason(e.target.value)} data-testid="agreement-override-reason" /></label>
        <button className="btn btn--ghost btn--sm" type="submit" disabled={pending || reason.trim().length < 5} data-testid="agreement-override">Override</button>
      </form>}
      {overrides.length > 0 && <p className="xs muted">Overridden: {overrides.map((o) => `${o.by ?? 'an Admin'}, "${o.reason}"`).join('; ')}.</p>}
    </div>
  );
}

export function AgreementActions({ booking, refresh, waiting, finance, disputes, docBase }: { booking: string; refresh: string[]; waiting: boolean; finance: boolean; docBase: string;
  disputes: Array<{ id: string; status: string; built_at: string | null; submitted_at: string | null; document_id: string | null; error: string | null }> }) {
  const router = useRouter();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const act = (f: () => Promise<{ ok: true } | { ok: false; message: string }>, ok: string) => start(async () => { const r = await f(); setMsg(r.ok ? { ok: true, text: ok } : { ok: false, text: r.message }); if (r.ok) router.refresh(); });
  return (
    <div className="stack">
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        {waiting && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => act(() => agreementResend(booking, refresh), 'The links went again by email and text.')} data-testid="agreement-resend">Resend the signing links</button>}
        <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => act(() => agreementRegenerate(booking, refresh), 'The agreements are checked against the booking now.')} data-testid="agreement-regenerate">Make the agreements again</button>
        {finance && <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => act(() => disputePackBuild(booking, refresh), 'The evidence pack is being built; it shows here in a minute.')} data-testid="dispute-pack-build">Build the dispute evidence pack</button>}
      </div>
      {disputes.map((d) => <p key={d.id} className="small" data-testid="dispute-pack">Dispute evidence pack: {d.status}{d.built_at ? `, built ${d.built_at.slice(0, 16).replace('T', ' ')}` : ''}{d.submitted_at ? `, submitted ${d.submitted_at.slice(0, 10)}` : ''}.
        {docBase && d.document_id && <> <a className="link" href={`${docBase}/${d.document_id}`} target="_blank" rel="noreferrer">Download</a></>}
        {finance && d.status === 'staged' && <> <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => act(() => disputePackSubmit(booking, d.id, refresh), 'Submitted to Stripe.')} data-testid="dispute-pack-submit">Submit to Stripe</button></>}
        {d.error && <span className="error"> {d.error}</span>}</p>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
