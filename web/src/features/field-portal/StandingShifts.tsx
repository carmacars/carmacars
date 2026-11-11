import '@/styles/shift-picker.css';
import { FieldButton } from '@/features/field/FieldButton';
import { WEEKDAYS, halfHours, type Standing } from './shift-picker';

// Standing weekly shifts (r35 part SP, 1770): "every Saturday 10 to 6". Matching published shifts are claimed for the person (up to
// two weeks ahead, capacity and the academy permitting). A date is dropped with a reason (the give-up rules), or the whole one ended.
const STATE: Record<string, string> = { claimed: 'claimed', skipped: 'dropped', waiting: 'claiming', no_slot: 'not published yet' };
const dayWords = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(`${d}T12:00:00Z`));

export function StandingShifts({ list, locked }: { list: Standing[]; locked: boolean }) {
  const hh = halfHours();
  return (
    <section className="fp-shiftcard sp-standing" aria-labelledby="sp-st-h" data-testid="standing">
      <h2 className="fp-shiftcard__when" id="sp-st-h">Standing weekly shifts</h2>
      <p className="small">Work the same shift every week? Set it once: each matching shift Fleet publishes is claimed for you, up to two weeks ahead, while it has room.{locked ? ' It starts once you pass the academy.' : ''}</p>
      {list.map((s) => <div key={s.id} className="sp-standing" data-testid="standing-row">
        <p><b>{s.words}</b></p>
        <ul aria-label="The next dates">{s.next.map((n) => <li key={n.day} className={`is-${n.state}`}>{dayWords(n.day)}: {STATE[n.state]}</li>)}</ul>
        {s.next.some((n) => n.state !== 'skipped') && <FieldButton action="standing_skip" payload={{ id: s.id }} label="Drop one date" sheet={{ confirm: 'Drop this date', title: 'A claimed date is given up: under 24 hours it is marked late' }}
          testId={`standing-skip-${s.id}`} fields={[{ name: 'day', label: 'Date', options: s.next.filter((n) => n.state !== 'skipped').map((n) => [n.day, dayWords(n.day)] as [string, string]) }, { name: 'reason', label: 'Why you cannot work it', required: true }]} />}
        <FieldButton action="standing_end" payload={{ id: s.id }} label="End this standing shift" sheet={{ confirm: 'End it', title: 'No more automatic claims. The shifts already claimed stay yours.' }} testId={`standing-end-${s.id}`} />
      </div>)}
      <FieldButton action="standing_add" payload={{}} label={list.length ? 'Add another standing shift' : 'Set a standing shift'} primary={!list.length} sheet={{ confirm: 'Set it', title: 'Every week, the same shift' }} testId="standing-add"
        fields={[{ name: 'weekday', label: 'Every', options: [6, 7, 1, 2, 3, 4, 5].map((d) => [String(d), WEEKDAYS[d - 1]!] as [string, string]) },
          { name: 'start', label: 'From', options: [...hh.filter(([v]) => v >= '10:00'), ...hh.filter(([v]) => v < '10:00')] },
          { name: 'end', label: 'To', options: [...hh.filter(([v]) => v >= '18:00'), ...hh.filter(([v]) => v < '18:00')] }]} />
    </section>
  );
}
