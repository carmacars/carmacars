'use client';
import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { DateRange } from '@/features/calendar/DateRange';
import { TimeSelect } from '@/features/calendar/TimeSelect';
import { torontoToday } from '@/lib/dates';

// The hero search: dates, times and pickup or delivery, carried to the fleet page in the address.
export function SearchForm({ maxDays }: { maxDays: number }) {
  const router = useRouter();
  const [d, setD] = useState({ from: '', to: '' });
  const [tf, setTf] = useState('10:00'); const [tt, setTt] = useState('10:00');
  const [mode, setMode] = useState('pickup');
  const [err, setErr] = useState('');
  const today = torontoToday();
  return (
    <form className="search" aria-label="Find a car" noValidate onSubmit={(e) => {
      e.preventDefault();
      if (d.from && !d.to) { setErr('Add a return date, or clear the dates to see every car.'); return; }
      const q = new URLSearchParams();
      if (d.from) { q.set('from', d.from); q.set('to', d.to); q.set('tf', tf); q.set('tt', tt); }
      if (mode === 'delivery') q.set('mode', 'delivery');
      router.push(`/cars${q.size ? '?' + q : ''}`);
    }}>
      <div className={`field search__dates${err ? ' has-error' : ''}`}>
        <DateRange id="hs" from={d.from} to={d.to} min={today} today={today} maxDays={maxDays} onChange={(v) => { setD(v); setErr(''); }} />
        <p className="error" role="alert">{err}</p>
      </div>
      <div className="search__times">
        <TimeSelect id="hs-tf" label="Pickup time" value={tf} onChange={setTf} />
        <TimeSelect id="hs-tt" label="Return time" value={tt} onChange={setTt} />
      </div>
      <fieldset className="field search__mode"><legend className="label">Pickup or delivery</legend>
        <div className="seg">
          <label><input type="radio" name="mode" value="pickup" checked={mode === 'pickup'} onChange={() => setMode('pickup')} />I’ll collect it</label>
          <label><input type="radio" name="mode" value="delivery" checked={mode === 'delivery'} onChange={() => setMode('delivery')} />Deliver it to me</label>
        </div>
      </fieldset>
      <button className="btn btn--primary btn--lg search__go" type="submit">Show cars</button>
    </form>
  );
}
