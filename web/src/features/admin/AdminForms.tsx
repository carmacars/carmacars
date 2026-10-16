'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { approveVehicleTerms, issueTrackerInvoices, recordTrackerInstalled, issueUpfrontInvoices, sendOwnerLink, setVehicleTerms, type TermsInput } from '@/server/actions/admin';

// The admin forms of the owner billing flow. Terms start from the standard grid; anything off the
// grid is the Admin's decision and is recorded as such by the database.
function F({ id, label, value, set, err, hint, ...props }: { id: string; label: string; value: string; set: (v: string) => void; err?: string; hint?: string } & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'value'>) {
  return (
    <div className={`field${err ? ' has-error' : ''}`}>
      <label className="label" htmlFor={id}>{label}</label>
      <input className="input" id={id} value={value} onChange={(e) => set(e.target.value)} aria-invalid={!!err || undefined} aria-describedby={`${id}-err${hint ? ` ${id}-hint` : ''}`} {...props} />
      {hint && <p className="hint" id={`${id}-hint`}>{hint}</p>}
      <p className="error" role="alert" id={`${id}-err`}>{err ?? ''}</p>
    </div>
  );
}
const Problem = ({ a }: { a: { res: { ok: true } | { ok: false; message: string; fieldErrors?: Record<string, string> } | null } }) => (a.res && !a.res.ok ? <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p> : null);
const dollars = (c: number | null | undefined) => (c === null || c === undefined ? '' : (c / 100).toFixed(2));

const METHODS: Record<string, string> = { lease_existing_corporation: 'Lease, existing corporation', lease_new_owner_corporation: 'Lease, new Owner Corporation', co_registrant: 'Co-Registrant', transfer: 'Transfer', none: 'None (Turo-Only)' };

export function TermsForm({ ownerId, vehicleId, standard, mode, method, options, current }: {
  ownerId: string; vehicleId: string; mode: string; method: string | null;
  standard: { insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; install_fee_cents: number; vehicle_count?: number } | null;
  options: Array<{ method: string; label: string; recommended: boolean }>;
  current: { insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; install_fee_cents: number; special_terms: string | null } | null;
}) {
  const router = useRouter();
  const a = useAct<{ status: string }>();
  const base = current ?? standard;
  const [t, setT] = useState<TermsInput>({
    management_mode: mode, onboarding_method: method ?? options.find((o) => o.recommended)?.method ?? options[0]?.method ?? (mode === 'turo_only' ? 'none' : ''),
    insurance: dollars(base?.insurance_fee_cents), tracker: dollars(base?.tracker_fee_cents), share: base ? String(base.revenue_share_bps / 100) : '', install: dollars(base?.install_fee_cents), special_terms: current?.special_terms ?? ''
  });
  const set = (k: keyof TermsInput) => (v: string) => setT({ ...t, [k]: v });
  const id = (k: string) => `ad-${vehicleId.slice(0, 8)}-${k}`;
  const offGrid = standard && (Math.round(Number(t.insurance) * 100) !== standard.insurance_fee_cents || Math.round(Number(t.tracker) * 100) !== standard.tracker_fee_cents
    || Math.round(Number(t.share) * 100) !== standard.revenue_share_bps || Math.round(Number(t.install) * 100) !== standard.install_fee_cents || t.special_terms.trim() !== '');
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => setVehicleTerms(ownerId, vehicleId, t), (r) => { if (r.ok) router.refresh(); }); }} aria-label="Terms" data-testid="terms-form">
      <div className="field-row">
        <div className="field"><label className="label" htmlFor={id('mode')}>Management Mode</label>
          <select className="select" id={id('mode')} value={t.management_mode} onChange={(e) => setT({ ...t, management_mode: e.target.value, share: e.target.value === 'self_managed' ? '0' : t.share })}>
            <option value="managed">Managed</option><option value="self_managed">Self-Managed</option><option value="turo_only">Turo-Only</option>
          </select></div>
        <div className={`field${a.err('onboarding_method') ? ' has-error' : ''}`}><label className="label" htmlFor={id('method')}>Onboarding Method</label>
          <select className="select" id={id('method')} value={t.onboarding_method} onChange={(e) => set('onboarding_method')(e.target.value)} aria-describedby={`${id('method')}-err`}>
            {t.management_mode === 'turo_only' ? <option value="none">None (Turo-Only)</option> : options.map((o) => <option key={o.method} value={o.method}>{o.label ?? METHODS[o.method]}{o.recommended ? ' (recommended)' : ''}</option>)}
          </select><p className="error" role="alert" id={`${id('method')}-err`}>{a.err('onboarding_method') ?? ''}</p></div>
      </div>
      <div className="field-row">
        <F id={id('ins')} label="Insurance Fee a month ($)" value={t.insurance} set={set('insurance')} err={a.err('insurance')} inputMode="decimal" />
        <F id={id('trk')} label="Tracker Fee a month ($)" value={t.tracker} set={set('tracker')} err={a.err('tracker')} inputMode="decimal" />
      </div>
      <div className="field-row">
        <F id={id('share')} label="Revenue Share (%)" value={t.share} set={set('share')} err={a.err('share')} inputMode="decimal" />
        <F id={id('inst')} label="Install Fee ($)" value={t.install} set={set('install')} err={a.err('install')} inputMode="decimal" />
      </div>
      <F id={id('special')} label="Special terms (optional)" value={t.special_terms} set={set('special_terms')} />
      {standard && <p className="small muted">Standard grid for {standard.vehicle_count ?? 1} vehicle{standard.vehicle_count === 1 ? '' : 's'}: ${dollars(standard.insurance_fee_cents)} insurance, ${dollars(standard.tracker_fee_cents)} tracker, {standard.revenue_share_bps / 100}% share, ${dollars(standard.install_fee_cents)} install.{offGrid ? ' These terms are off the grid: saving records your approval as Admin.' : ''}</p>}
      <Problem a={a} />
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>Terms saved.</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Saving' : current ? 'Update terms' : offGrid ? 'Approve and set terms' : 'Set terms (standard grid)'}</button>
    </form>
  );
}

export function PendingTerms({ ownerId, vehicleId }: { ownerId: string; vehicleId: string }) {
  const router = useRouter();
  const a = useAct();
  return (
    <div className="row">
      <button className="btn btn--primary btn--sm" type="button" disabled={a.pending} onClick={() => a.run(() => approveVehicleTerms(ownerId, vehicleId, true), (r) => { if (r.ok) router.refresh(); })}>Approve these terms</button>
      <button className="btn btn--ghost btn--sm" type="button" disabled={a.pending} onClick={() => a.run(() => approveVehicleTerms(ownerId, vehicleId, false), (r) => { if (r.ok) router.refresh(); })}>Refuse</button>
      <Problem a={a} />
    </div>
  );
}

export function IssueInvoices({ ownerId, count }: { ownerId: string; count: number }) {
  const router = useRouter();
  const a = useAct<{ count: number }>();
  return (
    <div className="stack">
      <button className="btn btn--primary" type="button" disabled={a.pending || count === 0} data-testid="issue-upfront" onClick={() => a.run(() => issueUpfrontInvoices(ownerId, null), (r) => { if (r.ok) router.refresh(); })}>{a.pending ? 'Issuing' : count === 0 ? 'Nothing to issue now' : `Issue ${count} insurance invoice${count === 1 ? '' : 's'}`}</button>
      <Problem a={a} />
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>{a.res.data.count} invoice{a.res.data.count === 1 ? '' : 's'} issued. The owner is emailed each one.</span></p>}
    </div>
  );
}

export function SendLinkForm({ kind, email: e0 = '', name: n0 = '' }: { kind: 'invite' | 'portal'; email?: string; name?: string }) {
  const a = useAct<{ url: string }>();
  const [email, setEmail] = useState(e0);
  const [name, setName] = useState(n0);
  const id = `ad-link-${kind}`;
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => sendOwnerLink(kind, email, name)); }} aria-label={kind === 'invite' ? 'Invite an owner' : 'Send a sign-in link'}>
      {kind === 'invite' && <F id={`${id}-n`} label="Name" value={name} set={setName} />}
      <F id={`${id}-e`} label="Email" type="email" value={email} set={setEmail} err={a.err('email')} />
      <Problem a={a} />
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>Sent. The link: <span className="pt-mono">{a.res.data.url}</span></span></p>}
      <button className="btn btn--ghost btn--sm" type="submit" disabled={a.pending}>{a.pending ? 'Sending' : kind === 'invite' ? 'Send invitation' : 'Send a sign-in link to the owner portal'}</button>
    </form>
  );
}

export function TrackerActions({ ownerId, vehicleId, label = 'Issue tracker install invoice', installed = true, canIssue = true }: { ownerId: string | null; vehicleId: string | null; label?: string; installed?: boolean; canIssue?: boolean }) {
  const router = useRouter();
  const a = useAct<{ count: number }>();
  const b = useAct();
  return (
    <div className="row">
      {canIssue && <button className="btn btn--ghost btn--sm" type="button" disabled={a.pending} data-testid={vehicleId ? `tracker-invoice-${vehicleId.slice(0, 8)}` : 'tracker-invoices-all'}
        onClick={() => a.run(() => issueTrackerInvoices(ownerId, vehicleId ? [vehicleId] : null), (r) => { if (r.ok) router.refresh(); })}>{a.pending ? 'Issuing' : label}</button>}
      {vehicleId && installed && <button className="btn btn--quiet btn--sm" type="button" disabled={b.pending} onClick={() => b.run(() => recordTrackerInstalled(ownerId ?? '', vehicleId), (r) => { if (r.ok) router.refresh(); })}>Record tracker installed today</button>}
      <Problem a={a} /><Problem a={b} />
      {a.res?.ok && <p className="small" role="status">{a.res.data.count} invoice{a.res.data.count === 1 ? '' : 's'} issued.</p>}
    </div>
  );
}
