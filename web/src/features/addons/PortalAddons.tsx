'use client';
import { useRouter } from 'next/navigation';
import { useState, useTransition } from 'react';
import { when } from '@/features/agreement/model';
import { money } from '@/lib/format';
import { buyAddon } from '@/server/actions/addons';
import { AddonPicker } from './AddonPicker';
import { addonPrice, type AddonChoice, type AddonOption, type BookingAddon } from './model';

export interface MyAddons { items: BookingAddon[]; can_add: boolean; cutoff_hours: number; add_until: string; options: AddonOption[]; card: { brand: string | null; last4: string | null } | null }

// The renter's add-ons (migration 0066): what is on the booking, and adding one after booking until the cutoff before
// pickup. Each is charged on the Card on File at once; one that needs our confirmation is only asked for.
export function PortalAddons({ number, data }: { number: string; data: MyAddons }) {
  const router = useRouter();
  const [pick, setPick] = useState<AddonChoice[]>([]);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const chosen = pick[0] ?? null;
  const opt = chosen ? data.options.find((o) => o.code === chosen.code) ?? null : null;
  const add = () => start(async () => {
    if (!chosen) return;
    setMsg(null);
    const r = await buyAddon(number, { code: chosen.code, quantity: chosen.quantity, hours: chosen.hours ?? null });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setPick([]);
    setMsg({ ok: true, text: r.data.status === 'pending' ? `${opt?.name ?? 'It'} is asked for. We confirm it and charge your card then.` : r.data.message ?? `${opt?.name ?? 'It'} is added and paid.` });
    router.refresh();
  });
  return (
    <section className="pt-card" aria-labelledby="pt-addons" data-testid="portal-addons"><h2 className="d4" id="pt-addons">Add-ons</h2>
      {data.items.length ? <ul className="pt-list">{data.items.map((a) => (
        <li key={a.id} className="pt-card__head" data-addon={a.code}><span>{a.quantity > 1 ? `${a.quantity} x ` : ''}{a.name}{a.hours ? `, ${+a.hours} hours` : ''}
          {a.status === 'pending' ? <span className="xs muted"> · waiting for our confirmation</span> : a.after_booking && !a.paid ? <span className="xs muted"> · to pay</span> : null}</span>
          <span className="num">{a.amount_cents !== null ? money((a.amount_cents ?? 0) + (a.hst_cents ?? 0), { cents: true }) : ''}</span></li>))}</ul>
        : <p className="muted small">No add-ons on this booking.</p>}
      {data.can_add && data.options.length > 0 && (
        <details className="stack" open={pick.length > 0}>
          <summary className="link">Add something to your trip</summary>
          <p className="small muted">Until {when(data.add_until)} (some need more notice). Charged now on your card{data.card?.last4 ? ` ending ${data.card.last4}` : ''}.</p>
          <AddonPicker idPrefix="pa" options={data.options} value={pick} onChange={(v) => setPick(v.filter((c) => c.code === v[v.length - 1]?.code))} />
          {chosen && opt && <p className="small" data-testid="portal-addon-price">{opt.name}: {addonPrice(opt)}{opt.hst_applies ? ', plus HST' : ''}.{opt.needs_confirmation ? ' We confirm it first and charge your card then.' : ''}</p>}
          <p><button className="btn btn--primary btn--sm" type="button" disabled={!chosen || pending} onClick={add} data-testid="portal-addon-add">{pending ? 'Adding' : opt?.needs_confirmation ? 'Ask for it' : 'Add and pay'}</button></p>
        </details>)}
      {!data.can_add && data.items.length === 0 && <p className="small muted">Add-ons can be added until {data.cutoff_hours} hours before pickup. Call us if you need something.</p>}
      {msg && <p className={`small ${msg.ok ? '' : 'error'}`} role="status">{msg.text}</p>}
    </section>
  );
}
