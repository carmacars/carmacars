'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { playMoment } from '@/features/motion/moment';
import { ownerRewardDo } from '@/server/actions/owner-rewards';
import { AddressLookup } from '@/features/forms/AddressFields';
import { addressProblem, type KitKind, type OwnerAddress, type OwnerRewards } from './model';

// The owner's Rewards buttons (release 48, migration 3262). A kit is never sent by itself: the owner presses Redeem,
// confirms where it goes, and the Admins get a To do to ship it. The form opens under its button (it grows from where
// the owner pressed) and the redeemed moment plays once.
const SIZES = ['S', 'M', 'L', 'XL', 'XXL'];

export function RedeemKit({ kind, name, address }: { kind: KitKind; name: string; address: OwnerAddress }) {
  const id = useId();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ name: address.name ?? '', line1: address.line1 ?? '', line2: address.line2 ?? '', city: address.city ?? '', province: address.province ?? 'ON', postal_code: address.postal_code ?? '', phone: address.phone ?? '', size: 'L' });
  const [err, setErr] = useState<string | null>(null);
  const a = useAct<OwnerRewards>();
  const router = useRouter();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => { setF((x) => ({ ...x, [k]: e.target.value })); setErr(null); a.setRes(null); };
  const send = () => {
    const p = addressProblem(f);
    setErr(p);
    if (p) return;
    a.run(() => ownerRewardDo('redeem_kit', { kind, ...f }), (r) => { if (r.ok) { playMoment('confirmed'); setOpen(false); router.refresh(); } });
  };
  if (!open) {
    return <button type="button" className="btn btn--primary" aria-expanded="false" aria-controls={`${id}-form`} onClick={() => setOpen(true)} data-testid={`or-redeem-${kind}`}>
      {kind === 'merch_kit' ? 'Redeem my merch kit' : 'Redeem my premium kit'}</button>;
  }
  return (
    <form className="rw-sheet stack" id={`${id}-form`} noValidate aria-label={`Where to send your ${name}`} data-testid={`or-redeem-form-${kind}`} onSubmit={(e) => { e.preventDefault(); if (!a.pending) send(); }}>
      <p className="small"><b>Where should we send it?</b> Check the address, then confirm.</p>
      <div className="rw-fields">
        <div className="field rw-fields__wide"><label className="label" htmlFor={`${id}-n`}>Name on the parcel</label><input className="input" id={`${id}-n`} value={f.name} onChange={set('name')} autoComplete="name" data-testid={`or-name-${kind}`} /></div>
        <div className="rw-fields__wide"><AddressLookup idp={`${id}-al`} onParts={(p) => { setF((x) => ({ ...x, line1: p.street || x.line1, line2: p.unit || x.line2, city: p.city || x.city, province: p.province || x.province, postal_code: p.postal_code || x.postal_code })); setErr(null); }} /></div>
        <div className="field rw-fields__wide"><label className="label" htmlFor={`${id}-l1`}>Street address</label><input className="input" id={`${id}-l1`} value={f.line1} onChange={set('line1')} autoComplete="address-line1" data-testid={`or-line1-${kind}`} /></div>
        <div className="field rw-fields__wide"><label className="label" htmlFor={`${id}-l2`}>Unit or suite <span className="small muted">(optional)</span></label><input className="input" id={`${id}-l2`} value={f.line2} onChange={set('line2')} autoComplete="address-line2" /></div>
        <div className="field"><label className="label" htmlFor={`${id}-c`}>City</label><input className="input" id={`${id}-c`} value={f.city} onChange={set('city')} autoComplete="address-level2" data-testid={`or-city-${kind}`} /></div>
        <div className="field"><label className="label" htmlFor={`${id}-p`}>Province</label><input className="input" id={`${id}-p`} value={f.province} onChange={set('province')} autoComplete="address-level1" /></div>
        <div className="field"><label className="label" htmlFor={`${id}-pc`}>Postal code</label><input className="input" id={`${id}-pc`} value={f.postal_code} onChange={set('postal_code')} autoComplete="postal-code" autoCapitalize="characters" data-testid={`or-postal-${kind}`} /></div>
        <div className="field"><label className="label" htmlFor={`${id}-ph`}>Phone for the courier <span className="small muted">(optional)</span></label><input className="input" id={`${id}-ph`} type="tel" inputMode="tel" value={f.phone} onChange={set('phone')} autoComplete="tel" /></div>
        <div className="field"><label className="label" htmlFor={`${id}-s`}>Shirt size</label><select className="select" id={`${id}-s`} value={f.size} onChange={set('size')}>{SIZES.map((s) => <option key={s} value={s}>{s}</option>)}</select></div>
      </div>
      {(err || (a.res && !a.res.ok)) && <p className="error" role="alert" data-testid={`or-redeem-error-${kind}`}>{err ?? (a.res && !a.res.ok ? a.res.message : '')}</p>}
      <p className="row rw-sheet__actions">
        <button className="btn btn--primary" type="submit" disabled={a.pending} aria-busy={a.pending || undefined} data-testid={`or-redeem-confirm-${kind}`}>{a.pending ? 'Sending' : 'Confirm and redeem'}</button>
        <button className="btn btn--ghost" type="button" disabled={a.pending} onClick={() => setOpen(false)}>Not now</button>
      </p>
    </form>
  );
}

export function UpgradeAsk({ cars }: { cars: Array<{ vehicle_id: string; name: string }> }) {
  const id = useId();
  const [open, setOpen] = useState(false);
  const [vehicle, setVehicle] = useState(cars.length === 1 ? cars[0]!.vehicle_id : '');
  const [note, setNote] = useState('');
  const a = useAct<OwnerRewards>();
  const router = useRouter();
  if (!open) return <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)} aria-expanded="false" data-testid="or-upgrade-open">Ask for a free upgrade</button>;
  return (
    <form className="rw-sheet stack" noValidate aria-label="Ask for a free upgrade" data-testid="or-upgrade-form" onSubmit={(e) => { e.preventDefault(); if (!a.pending) a.run(() => ownerRewardDo('upgrade_ask', { vehicle, note }), (r) => { if (r.ok) { setOpen(false); router.refresh(); } }); }}>
      <p className="small"><b>Is your car being repaired for something CarmaCars caused?</b> Tell us which car and what happened. An Admin answers here and by email.</p>
      <div className="field"><label className="label" htmlFor={`${id}-v`}>Which car</label>
        <select className="select" id={`${id}-v`} value={vehicle} onChange={(e) => { setVehicle(e.target.value); a.setRes(null); }} data-testid="or-upgrade-car">
          <option value="">Choose</option>{cars.map((c) => <option key={c.vehicle_id} value={c.vehicle_id}>{c.name}</option>)}</select></div>
      <div className="field"><label className="label" htmlFor={`${id}-t`}>What happened</label>
        <textarea className="input" id={`${id}-t`} rows={3} maxLength={600} value={note} onChange={(e) => { setNote(e.target.value); a.setRes(null); }} data-testid="or-upgrade-note" /></div>
      {a.res && !a.res.ok && <p className="error" role="alert" data-testid="or-upgrade-error">{a.res.message}</p>}
      <p className="row rw-sheet__actions">
        <button className="btn btn--primary" type="submit" disabled={a.pending} aria-busy={a.pending || undefined} data-testid="or-upgrade-send">{a.pending ? 'Sending' : 'Send my request'}</button>
        <button className="btn btn--ghost" type="button" disabled={a.pending} onClick={() => setOpen(false)}>Not now</button>
      </p>
    </form>
  );
}

export function UpgradeCancel({ id }: { id: string }) {
  const a = useAct<OwnerRewards>();
  const router = useRouter();
  return <>
    <button type="button" className="btn btn--quiet btn--sm" disabled={a.pending} aria-busy={a.pending || undefined} onClick={() => a.run(() => ownerRewardDo('upgrade_cancel', { id }), (r) => { if (r.ok) router.refresh(); })} data-testid="or-upgrade-cancel">Cancel my request</button>
    {a.res && !a.res.ok && <span className="error" role="alert">{a.res.message}</span>}
  </>;
}
