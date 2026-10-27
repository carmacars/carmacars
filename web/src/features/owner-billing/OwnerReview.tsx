'use client';
import { useId, useState } from 'react';
import { AddressLookup } from '@/features/forms/AddressFields';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useAct } from '@/features/portal/useAct';
import { money } from '@/lib/format';
import { ownerCorrect, signScheduleChange } from '@/server/actions/owner-billing';
import { EsignFlow } from '@/features/signing/EsignFlow';
import { DOC_TERMS } from '@/features/signing/terms';
import type { EsignReady } from '@/features/signing/types';

// The owner checks what CarmaCars entered for them and corrects it before signing (migration 0067), and signs an
// updated Vehicle Schedule.
export interface ReviewData {
  owner: { legal_name: string; email: string | null; phone: string | null; address_line1: string | null; address_line2: string | null; city: string | null; province: string | null; postal_code: string | null };
  cars: Array<{ vehicle_id: string; name: string; vin: string; plate: string | null; colour: string | null; odometer_km: number | null; current_insurer: string | null; finance_party_name: string | null;
    title_status: string | null; editable: boolean; entered_by_staff: boolean;
    terms: { schedule_number: string; insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; install_fee_cents: number; first_last_cents: number; one_off_fees: Array<{ description: string; amount_cents: number }> } | null }>;
  editable: boolean;
}
export function OwnerReview({ data, trackers }: { data: ReviewData; trackers: boolean }) {
  const router = useRouter();
  const a = useAct<{ changes: number }>();
  const uid = `or-${useId().replace(/[^\w-]/g, '')}`;
  const [o, setO] = useState<Record<string, string>>({ phone: data.owner.phone ?? '', address_line1: data.owner.address_line1 ?? '', address_line2: data.owner.address_line2 ?? '', city: data.owner.city ?? '', province: data.owner.province ?? 'ON', postal_code: data.owner.postal_code ?? '' });
  const [cars, setCars] = useState<Record<string, Record<string, string>>>(() => Object.fromEntries(data.cars.map((c) => [c.vehicle_id, { plate: c.plate ?? '', colour: c.colour ?? '', odometer_km: c.odometer_km ? String(c.odometer_km) : '', current_insurer: c.current_insurer ?? '', finance_party_name: c.finance_party_name ?? '' }])));
  const input = (id: string, label: string, value: string, set: (v: string) => void, disabled: boolean, mode?: 'numeric' | 'tel') => (
    <div className="field"><label className="label" htmlFor={id}>{label}</label><input className="input" id={id} value={value} disabled={disabled} inputMode={mode} onChange={(e) => set(e.target.value)} data-testid={`review-${id.split('-').pop()}`} /></div>);
  const save = () => a.run(() => ownerCorrect({ owner: data.editable ? o : undefined, cars: data.cars.filter((c) => c.editable).map((c) => ({ vehicle_id: c.vehicle_id, ...cars[c.vehicle_id] })) }), (r) => { if (r.ok) router.refresh(); });
  return (
    <form className="stack-lg" noValidate aria-label="Review your details" data-testid="owner-review" onSubmit={(e) => { e.preventDefault(); save(); }}>
      <section className="pt-card stack" aria-labelledby={`${uid}-me`}><h2 className="d4" id={`${uid}-me`}>You</h2>
        <p className="small">{data.owner.legal_name}{data.owner.email ? ` · ${data.owner.email}` : ''}. A change to your legal name or email: tell us, it changes your agreements.</p>
        <div className="ad-fields ob-terms">
          {input(`${uid}-phone`, 'Phone', o.phone!, (v) => setO({ ...o, phone: v }), !data.editable, 'tel')}
          {data.editable && <AddressLookup idp={`${uid}-addr`} onParts={(p) => setO((x) => ({ ...x, address_line1: p.street || x.address_line1!, address_line2: p.unit || x.address_line2!, city: p.city || x.city!, province: p.province || x.province!, postal_code: p.postal_code || x.postal_code! }))} />}
          {input(`${uid}-address_line1`, 'Street address', o.address_line1!, (v) => setO({ ...o, address_line1: v }), !data.editable)}
          {input(`${uid}-address_line2`, 'Unit (optional)', o.address_line2!, (v) => setO({ ...o, address_line2: v }), !data.editable)}
          {input(`${uid}-city`, 'City', o.city!, (v) => setO({ ...o, city: v }), !data.editable)}
          {input(`${uid}-postal_code`, 'Postal code', o.postal_code!, (v) => setO({ ...o, postal_code: v }), !data.editable)}
        </div>
      </section>
      {data.cars.map((c) => {
        const v = cars[c.vehicle_id]!; const set = (k: string) => (x: string) => setCars({ ...cars, [c.vehicle_id]: { ...v, [k]: x } });
        return (
          <section key={c.vehicle_id} className="pt-card stack" aria-label={c.name} data-testid="review-car">
            <div className="pt-card__head"><h2 className="d4">{c.name}</h2>{c.entered_by_staff && <span className="badge badge--outline">Set up by CarmaCars</span>}</div>
            <p className="small muted">VIN {c.vin}</p>
            <div className="ad-fields ob-terms">
              {input(`${uid}-${c.vehicle_id.slice(0, 6)}-plate`, 'Plate', v.plate!, set('plate'), !c.editable)}
              {input(`${uid}-${c.vehicle_id.slice(0, 6)}-colour`, 'Colour', v.colour!, set('colour'), !c.editable)}
              {input(`${uid}-${c.vehicle_id.slice(0, 6)}-odometer_km`, 'Odometer (km)', v.odometer_km!, set('odometer_km'), !c.editable, 'numeric')}
              {input(`${uid}-${c.vehicle_id.slice(0, 6)}-current_insurer`, 'Your insurer now', v.current_insurer!, set('current_insurer'), !c.editable)}
              {c.title_status !== 'owned_outright' && input(`${uid}-${c.vehicle_id.slice(0, 6)}-finance_party_name`, c.title_status === 'leased' ? 'Lease company' : 'Lender', v.finance_party_name!, set('finance_party_name'), !c.editable)}
            </div>
            {c.terms && <dl className="pt-dl pt-dl--money" data-testid="review-terms">
              <div><dt>Insurance Fee a month</dt><dd>{money(c.terms.insurance_fee_cents, { cents: true })}</dd></div>
              {trackers && <div><dt>Tracker Fee a month</dt><dd>{money(c.terms.tracker_fee_cents, { cents: true })}</dd></div>}
              <div><dt>Revenue Share</dt><dd>{+(c.terms.revenue_share_bps / 100).toFixed(2)}%</dd></div>
              <div><dt>First and last month, before HST</dt><dd data-testid="review-first-last">{money(c.terms.first_last_cents, { cents: true })}</dd></div>
              {c.terms.one_off_fees.map((f, k) => <div key={k}><dt>{f.description}</dt><dd>{money(f.amount_cents, { cents: true })}</dd></div>)}
            </dl>}
            {!c.editable && <p className="small muted">Its Vehicle Schedule is signed. To change anything, message us.</p>}
          </section>);
      })}
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && <p className="alert alert--ok" role="status" data-testid="review-saved"><span>Saved. Your documents are filled in again with these details. We were told.</span></p>}
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <button className="btn btn--ghost" type="submit" disabled={a.pending || (!data.editable && !data.cars.some((c) => c.editable))} data-testid="review-save">{a.pending ? 'Saving' : 'Save corrections'}</button>
        <Link prefetch={false} className="btn btn--primary" href="/owner/sign" data-testid="review-sign">Everything is right: sign</Link>
      </div>
      <p className="small muted">Something about the terms is not what we agreed? Message us before you sign.</p>
    </form>
  );
}

// An updated Vehicle Schedule, signed with the signing steps of every signature (0182): a code to the owner's phone or
// email, the reading, the updated terms initialled, the consents, the drawn signature. The signed copy, with the
// certificate of completion, is filed in Documents.
export function ScheduleSign({ changeId, sha256, owner, title, signed }: { changeId: string; sha256: string; owner: string; title: string; signed: boolean }) {
  const router = useRouter();
  const a = useAct<{ schedule_number: string }>();
  const [ready, setReady] = useState<EsignReady | null>(null);
  if (signed || a.res?.ok) return <p className="alert alert--ok" role="status" data-testid="schedule-signed"><span>Signed. Your updated Vehicle Schedule{a.res?.ok ? ` ${a.res.data.schedule_number}` : ''} is in force from its date. The signed copy is in Documents.</span></p>;
  return (
    <form className="stack" noValidate aria-label="Sign the updated Vehicle Schedule" data-testid="schedule-sign" onSubmit={(e) => { e.preventDefault(); if (ready) a.run(() => signScheduleChange(changeId, owner, sha256, ready), (r) => { if (r.ok) router.refresh(); }); }}>
      <EsignFlow ctx={{ kind: 'documents', role: 'owner', docs: [{ kind: 'schedule_change', ref: changeId, sha: sha256, title }] }} terms={DOC_TERMS} docsLabel="this updated Vehicle Schedule" onReady={setReady} />
      {a.err('signature') && <p className="error" role="alert">{a.err('signature')}</p>}
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={a.pending || !ready} data-testid="schedule-sign-submit">{a.pending ? 'Signing' : 'Sign'}</button></div>
    </form>
  );
}
