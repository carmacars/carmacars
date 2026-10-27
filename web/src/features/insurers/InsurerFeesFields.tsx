'use client';
import { money } from '@/lib/format';
import { INSURER_FEES, feeForDays, rateCents, rateProblem } from './fees';

// The charges to the insurer (migration 0180), a rate a day each: on Add a rental (insurance replacement), the review
// screen of a booking billed to an insurer and the booking's Insurance replacement card. Shown only for a booking billed to
// an insurer; the database refuses them on any other.
export function InsurerFeesFields({ idPrefix, value, onChange, days, disabled = false }: {
  idPrefix: string; value: Record<string, string>; onChange: (code: string, dollars: string) => void; days: number; disabled?: boolean;
}) {
  const fmt = (c: number) => money(c, { cents: true });
  return (
    <fieldset className="ad-field ad-field--wide stack" data-testid={`${idPrefix}-insurer-fees`}>
      <legend className="label">Charges to the insurer (rate a day, before HST)</legend>
      <p className="hint">Only what the insurer authorized. Each is the rate times the rental days, plus HST, and prints in its box on Blind Spot&apos;s agreement. Leave empty for none.</p>
      <div className="ad-fields">
        {INSURER_FEES.map((f) => {
          const id = `${idPrefix}-fee-${f.code}`;
          const v = value[f.code] ?? '';
          const bad = rateProblem(v);
          const sum = feeForDays(rateCents(v), days, fmt);
          return (
            <div className="field ad-field" key={f.code}>
              <label className="label" htmlFor={id}>{f.label} ($ a day)</label>
              <input className="input" id={id} inputMode="decimal" value={v} disabled={disabled} placeholder="0.00"
                onChange={(e) => onChange(f.code, e.target.value)} data-testid={id} aria-invalid={bad ? true : undefined} aria-describedby={`${id}-h`} />
              {bad ? <p className="error" role="alert" id={`${id}-h`}>{bad}</p> : <p className="hint" id={`${id}-h`}>{sum || ' '}</p>}
            </div>);
        })}
      </div>
    </fieldset>
  );
}
