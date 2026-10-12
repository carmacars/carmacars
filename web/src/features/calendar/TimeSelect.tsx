'use client';
import { clock, timeSlots } from '@/lib/dates';

const SLOTS = timeSlots(30);
export function TimeSelect({ id, label, value, onChange, name }: { id: string; label: string; value: string; name?: string; onChange: (v: string) => void }) {
  return (
    <div className="field">
      <label className="label" htmlFor={id}>{label}</label>
      <select className="select" id={id} name={name} value={value} onChange={(e) => onChange(e.target.value)}>
        {SLOTS.map((t) => <option key={t} value={t}>{clock(t)}</option>)}
      </select>
    </div>
  );
}
