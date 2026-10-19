'use client';

// The choice on every rental, quote and offer a staff member enters (migration 0058): "I sourced this client" earns the
// staff commission once the rental is completed and paid; "Entered for CarmaCars" earns none.
export type Choice = '' | 'sourced' | 'for_carmacars';
export function SourcedChoice({ value, onChange, id, optional }: { value: Choice; onChange: (v: Choice) => void; id: string; optional?: boolean }) {
  return (
    <fieldset className="stack" data-testid={`${id}-choice`}>
      <legend className="label">Who found this client?{optional ? ' (optional for an Admin)' : ''}</legend>
      <label className="check ad-choice" htmlFor={`${id}-sourced`}>
        <input type="radio" id={`${id}-sourced`} name={`${id}-choice`} value="sourced" checked={value === 'sourced'} onChange={() => onChange('sourced')} data-testid="choice-sourced" />
        <span><b>I sourced this client</b><br /><span className="small muted">You found this renter yourself. You earn your commission when the rental is completed and paid in full, after an Admin approves it.</span></span>
      </label>
      <label className="check ad-choice" htmlFor={`${id}-carmacars`}>
        <input type="radio" id={`${id}-carmacars`} name={`${id}-choice`} value="for_carmacars" checked={value === 'for_carmacars'} onChange={() => onChange('for_carmacars')} data-testid="choice-for_carmacars" />
        <span><b>Entered for CarmaCars</b><br /><span className="small muted">The renter came to CarmaCars (the website, the phone line, a walk-in, a partner). No commission.</span></span>
      </label>
    </fieldset>
  );
}

/** What a price typed by hand would be flagged for (the database decides; this is the preview). */
export function priceFlags(cents: number | undefined, rateSheet: number | null | undefined, days: number | null | undefined, floorDaily: number | null | undefined, maxDiscountBps: number | null | undefined): string[] {
  if (cents === undefined || !Number.isFinite(cents)) return [];
  const out: string[] = [];
  if (floorDaily !== null && floorDaily !== undefined && cents < floorDaily * Math.max(days ?? 1, 1)) out.push('under the price floor');
  if (rateSheet && maxDiscountBps !== null && maxDiscountBps !== undefined && (rateSheet - cents) * 10000 > rateSheet * maxDiscountBps) out.push(`more than ${maxDiscountBps / 100}% under the rate sheet`);
  return out;
}
