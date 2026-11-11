import '@/styles/shift-picker.css';
import { PARTS, WEEKDAYS, WEEKDAYS_SHORT, cell, availabilityWords } from './shift-picker';

// A person's availability at a glance (Fleet and Admin, the field jobs board): 7 x 3 dots and the words, with the note.
export function AvailabilityMini({ slots, note }: { slots: string[] | null | undefined; note?: string | null }) {
  if (!slots?.length) return <span className="ad-flag ad-flag--red" data-testid="avail-missing">not given</span>;
  const on = new Set(slots);
  return (
    <span className="sp-mini" data-testid="avail-mini">
      <span className="sp-mini__dots" role="img" aria-label={availabilityWords(slots)}>
        {WEEKDAYS.map((w, i) => <span key={w} className="sp-mini__col"><b aria-hidden="true">{WEEKDAYS_SHORT[i]![0]}</b>
          {PARTS.map((p) => <i key={p.key} className={on.has(cell(i + 1, p.key)) ? 'is-on' : undefined} />)}</span>)}
      </span>
      <span className="small">{availabilityWords(slots)}{note ? `. ${note}` : ''}</span>
    </span>
  );
}
