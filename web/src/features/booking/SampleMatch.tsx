'use client';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { browserRpc } from '@/lib/browser-rpc';
import { torontoInstant } from '@/lib/dates';

// A sample (example) car with dates chosen (0102): the best real car free for those dates (public.sample_car_match: the
// same make and model first, then the same class and body at a similar price), offered in one tap. With none free, the
// page's example car note stays: we find a similar real car.
export interface Match { vehicle_id: string; slug: string; name: string; label: string; from_cents: number; match: 'same_model' | 'similar' }

export function useSampleMatch(vehicleId: string | null, from: string, to: string, tf: string, tt: string) {
  const key = vehicleId && from && to ? `${vehicleId}|${from}|${to}|${tf}|${tt}` : '';
  const [got, setGot] = useState<{ key: string; m: Match | null } | null>(null);
  useEffect(() => {
    if (!key || !vehicleId) return;
    let live = true;
    browserRpc<Match | null>('sample_car_match', { p_vehicle: vehicleId, p_pickup: torontoInstant(from, tf), p_return: torontoInstant(to, tt) })
      .then((m) => { if (live) setGot({ key, m: m ?? null }); }).catch(() => { if (live) setGot({ key, m: null }); });
    return () => { live = false; };
  }, [key, vehicleId, from, to, tf, tt]);
  return got && got.key === key ? { m: got.m, done: true } : { m: null, done: !key };
}

export function SampleMatch({ vehicleId, name, from, to, tf, tt, onSwitch, href }: {
  vehicleId: string; name: string; from: string; to: string; tf: string; tt: string; onSwitch?: (slug: string) => void; href?: (slug: string) => string;
}) {
  const { m, done } = useSampleMatch(vehicleId, from, to, tf, tt);
  if (!from || !to || !done) return null;
  // none free: the page's example car note stays (we find a similar real car)
  if (!m) return null;
  const price = `from $${(m.from_cents / 100).toLocaleString('en-CA', { minimumFractionDigits: m.from_cents % 100 ? 2 : 0, maximumFractionDigits: 2 })} a day`;
  return (
    <div className="alert alert--ok" role="status" data-testid="sample-match">
      <span className="alert__title">Good news: we have a {m.name} free for your dates</span>
      <span>The {name} is an example car. The {m.label.replace(/, from \$[\d,.]+ a day$/, '')} is a real car, {price}. Switch to it and the price beside the form is the real one.</span>
      <span className="row">
        {onSwitch ? <button type="button" className="btn btn--primary" data-testid="sample-match-switch" onClick={() => onSwitch(m.slug)}>Switch to the {m.name}</button>
          : <Link className="btn btn--primary" data-testid="sample-match-switch" href={href ? href(m.slug) : `/cars/${m.slug}`}>Book the {m.name} instead</Link>}
      </span>
    </div>
  );
}
