'use client';
import { useEffect, useState } from 'react';
import { browserRpc } from '@/lib/browser-rpc';
import { torontoInstant } from '@/lib/dates';
import { photoUrl } from '@/lib/photo';
import { addonNotes, addonPrice, choiceOf, selectable, type AddonChoice, type AddonOption } from './model';

/** The add-ons offered for a car (and what is left for the dates), read as the public reads them. */
export function useAddonOptions(vehicleId: string | null, from?: string, to?: string, tf?: string, tt?: string) {
  const [got, setGot] = useState<{ key: string; options: AddonOption[]; failed: boolean } | null>(null);
  const key = vehicleId ? [vehicleId, from, to, tf, tt].join('|') : '';
  useEffect(() => {
    if (!vehicleId) return;
    let live = true;
    const t = setTimeout(() => {
      browserRpc<AddonOption[]>('addons_for_car', { p_vehicle: vehicleId, p_pickup: from && tf ? torontoInstant(from, tf) : null, p_return: to && tt ? torontoInstant(to, tt) : null })
        .then((r) => { if (live) setGot({ key, options: r ?? [], failed: false }); })
        .catch(() => { if (live) setGot({ key, options: [], failed: true }); });
    }, 200);
    return () => { live = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  const mine = got && got.key === key ? got : null;
  return { options: mine?.options ?? got?.options ?? [], failed: mine?.failed ?? false, loading: !mine };
}

/**
 * Choose add-ons: a tick for one-per-booking items, a count for seats, the hours for a chauffeur. The price shown is
 * the catalogue's; the total is always the quote's or the booking's (the caller shows it).
 */
export function AddonPicker({ options, value, onChange, idPrefix = 'ao', staff = false, compact = false }: {
  options: AddonOption[]; value: AddonChoice[]; onChange: (v: AddonChoice[]) => void; idPrefix?: string; staff?: boolean; compact?: boolean;
}) {
  const put = (code: string, next: AddonChoice | null) => {
    const rest = value.filter((c) => c.code !== code);
    onChange(next && next.quantity > 0 ? [...rest, next] : rest);
  };
  if (!options.length) return <p className="small muted">No add-ons are offered for this car.</p>;
  return (
    <ul className={`addons${compact ? ' addons--compact' : ''}`} data-testid={`${idPrefix}-addons`}>
      {options.map((o) => {
        const c = choiceOf(value, o.code);
        const can = selectable(o, staff) || !!c;
        const id = `${idPrefix}-${o.code}`;
        const notes = addonNotes(o, staff);
        const hoursOpts = Array.from({ length: 13 }, (_, i) => i + Math.max(1, Math.ceil(o.min_hours ?? 1))).filter((h) => h <= 14);
        return (
          <li key={o.code} className={`addon${c ? ' is-on' : ''}${can ? '' : ' is-off'}`} data-addon={o.code}>
            {o.photo_path && !compact && (
              // eslint-disable-next-line @next/next/no-img-element
              <img className="addon__img" src={photoUrl(o.photo_path)} alt="" width={96} height={96} loading="lazy" />
            )}
            <div className="addon__body">
              {o.max_per_booking > 1 ? (
                <span className="addon__title" id={`${id}-l`}><b>{o.name}</b> <span className="muted num">{addonPrice(o)}</span></span>
              ) : (
                <label className="check addon__title" htmlFor={id}>
                  <input type="checkbox" id={id} checked={!!c} disabled={!can}
                    onChange={(e) => put(o.code, e.target.checked ? { code: o.code, quantity: 1, hours: o.pricing_unit === 'per_hour' ? (o.min_hours ?? 1) : null } : null)} />
                  <span><b>{o.name}</b> <span className="muted num">{addonPrice(o)}</span></span>
                </label>
              )}
              {o.description && !compact && <span className="small muted addon__desc">{o.description}</span>}
              {notes.length > 0 && <span className="xs muted addon__notes">{notes.join(' · ')}</span>}
              {c && o.pricing_unit === 'per_hour' && (
                <span className="addon__hours"><label className="small" htmlFor={`${id}-h`}>Hours</label>
                  <select className="select select--sm" id={`${id}-h`} value={String(c.hours ?? o.min_hours ?? 1)}
                    onChange={(e) => put(o.code, { ...c, hours: Number(e.target.value) })}>
                    {hoursOpts.map((h) => <option key={h} value={h}>{h} hours</option>)}
                  </select></span>
              )}
            </div>
            {o.max_per_booking > 1 && (
              <div className="qty">
                <button type="button" aria-label={`Fewer: ${o.name}`} disabled={!c} onClick={() => put(o.code, c ? { ...c, quantity: c.quantity - 1 } : null)}>−</button>
                <output aria-labelledby={`${id}-l`} data-testid={`${id}-count`}>{c?.quantity ?? 0}</output>
                <button type="button" aria-label={`More: ${o.name}`}
                  disabled={!can || (c?.quantity ?? 0) >= o.max_per_booking || (o.available !== null && o.available !== undefined && !staff && (c?.quantity ?? 0) >= o.available)}
                  onClick={() => put(o.code, { code: o.code, quantity: (c?.quantity ?? 0) + 1, hours: null })}>+</button>
              </div>
            )}
          </li>
        );
      })}
    </ul>
  );
}
