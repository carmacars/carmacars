'use client';
import { useEffect, useState } from 'react';
import { offersRead } from '@/server/actions/offers';
import { addressWords, licenceWords, profileFlags, type ProfileDriver, type RenterProfile } from './profile-fill';

// r45 (2860): staff pick an existing renter on Send an offer or Add a rental and see what is on file (the licence, the
// home address, the drivers named before), with what is out of date flagged to ask the renter about. The booking takes
// the renter's record; onDrivers (Add a rental) fills its additional drivers from the ones on file in one tap.
const todayIso = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export function RenterOnFile({ renterId, returnIso, onDrivers, testId = 'renter-on-file' }: { renterId: string | null; returnIso?: string | null; onDrivers?: (d: ProfileDriver[]) => void; testId?: string }) {
  const [p, setP] = useState<RenterProfile | null>(null);
  useEffect(() => {
    let live = true;
    if (!renterId) { queueMicrotask(() => { if (live) setP(null); }); return () => { live = false; }; }
    offersRead<RenterProfile>('renter_profile_fill', { renter: renterId }).then((r) => { if (live) setP(r.ok ? r.data : null); }).catch(() => undefined);
    return () => { live = false; };
  }, [renterId]);
  if (!p || p.renter_id !== renterId) return null;
  const flags = profileFlags(p, { todayIso: todayIso(), returnIso: returnIso?.slice(0, 10) || null, staff: true });
  if (!p.licence && !p.address && !p.drivers.length) return null;
  return (
    <div className="small stack" data-testid={testId} style={{ gap: 'var(--s-1)' }}>
      {p.licence && <span>Licence on file: {licenceWords(p.licence, true)}</span>}
      {p.address && <span>Home address: {addressWords(p.address)}</span>}
      {p.drivers.length > 0 && <span>Drivers named before: {p.drivers.map((x) => x.full_name).join(', ')}{onDrivers && <> <button type="button" className="btn btn--quiet btn--sm" onClick={() => onDrivers(p.drivers)} data-testid={`${testId}-drivers`}>Add them</button></>}</span>}
      {flags.map((f) => <span key={f.key} className="error" data-testid={`${testId}-stale-${f.key}`}>{f.message}</span>)}
    </div>
  );
}
