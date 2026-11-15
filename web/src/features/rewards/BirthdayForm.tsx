'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { saveBirthday } from '@/server/actions/rewards';
import { birthdayProblem, MONTH_OPTIONS } from './occasions';
import type { RewardBirthday } from './types';

// r48 (3001): the renter's birthday for the Rewards birthday reward. The licence's date of birth is used when we have it
// (shown, not asked); otherwise a month and a day, the year optional. On the Rewards page and Account > Profile.
export function BirthdayForm({ b, idp = 'bd' }: { b: RewardBirthday | null | undefined; idp?: string }) {
  const [m, setM] = useState(b?.month ? String(b.month) : '');
  const [d, setD] = useState(b?.day ? String(b.day) : '');
  const [y, setY] = useState(b?.year ? String(b.year) : '');
  const [err, setErr] = useState<string | null>(null);
  const a = useAct<{ saved: boolean }>();
  const router = useRouter();
  if (b?.from_licence) return <p className="small" data-testid={`${idp}-licence`}>Your birthday, <b>{b.label}</b>, comes from your driver&apos;s licence.</p>;
  const save = () => {
    const p = birthdayProblem(m, d, y);
    setErr(p);
    if (p) return;
    a.run(() => saveBirthday(m ? Number(m) : null, d ? Number(d) : null, y ? Number(y) : null), (r) => { if (r.ok) router.refresh(); });
  };
  return (
    <form className="stack" noValidate data-testid={`${idp}-form`} onSubmit={(e) => { e.preventDefault(); if (!a.pending) save(); }}>
      <div className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'flex-end' }}>
        <div className="field"><label className="label" htmlFor={`${idp}-m`}>Month</label>
          <select className="select" id={`${idp}-m`} value={m} onChange={(e) => { setM(e.target.value); a.setRes(null); }} autoComplete="bday-month">
            <option value="">Choose</option>{MONTH_OPTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
        <div className="field"><label className="label" htmlFor={`${idp}-d`}>Day</label>
          <input className="input" id={`${idp}-d`} inputMode="numeric" maxLength={2} size={3} value={d} onChange={(e) => { setD(e.target.value.replace(/\D/g, '')); a.setRes(null); }} autoComplete="bday-day" /></div>
        <div className="field"><label className="label" htmlFor={`${idp}-y`}>Year <span className="small muted">(optional)</span></label>
          <input className="input" id={`${idp}-y`} inputMode="numeric" maxLength={4} size={5} value={y} onChange={(e) => { setY(e.target.value.replace(/\D/g, '')); a.setRes(null); }} autoComplete="bday-year" /></div>
      </div>
      {(err || (a.res && !a.res.ok)) && <p className="error" role="alert">{err ?? (a.res && !a.res.ok ? a.res.message : '')}</p>}
      {a.res?.ok && <p className="small" role="status">Saved.</p>}
      <p><button className="btn btn--ghost btn--sm" type="submit" disabled={a.pending} data-testid={`${idp}-save`}>{a.pending ? 'Saving' : 'Save my birthday'}</button></p>
    </form>
  );
}
