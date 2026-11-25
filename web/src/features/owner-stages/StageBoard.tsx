import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { ContactButtons } from '@/features/phone/QuoButtons';
import './owner-stages.css';
import { ACTOR_WORDS, columns, daysWords, fillScript, type Board } from './model';

// The Owner pipeline board (r50, 4511) for Sales (the owners they brought in), customer service, Fleet and the Admins:
// every owner and car by stage, days in stage, the next action and whose it is, a one-tap nudge (branded email and text)
// and the stage's call script.
export function StageBoard({ b, base, refresh }: { b: Board; base: '/admin' | '/staff'; refresh: string[] }) {
  const cols = columns(b);
  const script = Object.fromEntries(b.stages.map((s) => [s.code, s.call_script]));
  return (
    <section className="stack" aria-labelledby="osb-h" data-testid="os-board" data-guide="os-board">
      <h2 className="d4" id="osb-h">Owners onboarding <span className="small muted">({b.cars.length})</span></h2>
      <p className="small muted">Every owner&apos;s car by step, how long it has waited and whose turn it is. A car waiting {b.stall_days} days or more is marked stalled; the Admins are alerted and the salesperson gets a To do.</p>
      {b.cars.length === 0 ? <p className="small" data-testid="os-board-empty">No owner is onboarding a car right now.</p> : <div className="osb">
        {cols.map((c) => (
          <section key={c.code} className="pt-card osb-col" aria-labelledby={`osb-${c.code}`} data-testid={`os-col-${c.code}`}>
            <h3 className="d5" id={`osb-${c.code}`}>{c.label} <span className="small muted">({c.cars.length})</span></h3>
            {c.cars.length ? <ul className="osb-list">{c.cars.map((x) => (
              <li key={x.vehicle_id} className={`osb-card ${x.stalled ? 'osb-card--stalled' : ''}`} data-testid="os-board-car" data-guide="os-board-car" data-vehicle={x.vehicle_id} data-stalled={x.stalled ? 'yes' : 'no'}> 
                <b><Link prefetch={false} className="link" href={`${base}/owners/${x.owner_id}`}>{x.owner_name}</Link></b>
                <span className="small">{x.car}{x.plate ? `, ${x.plate}` : ''}</span>
                <span className="xs muted">{x.route_label}</span>
                <span className="xs"><b>{daysWords(x.days_in_stage)}</b> in this step{x.stalled ? ', stalled' : ''}. {x.actor ? `Waiting on ${ACTOR_WORDS[x.actor]}` : ''}.</span>
                <span className="xs"><b>Next:</b> {x.next_action}</span>
                {x.salesperson && <span className="xs muted">Sales: {x.salesperson}</span>}
                {x.last_nudge_at && <span className="xs muted">Nudged {x.nudges} time{x.nudges === 1 ? '' : 's'}, last {new Date(x.last_nudge_at).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' })}</span>}
                <span className="ad-actions">
                  {x.actor === 'owner' && x.has_login && <Act action="owner_stage_do" payload={{ vehicle_id: x.vehicle_id, op: 'nudge' }} label="Nudge" variant="primary" refresh={refresh} done="Reminder sent: email and text." testId={`os-board-nudge-${x.vehicle_id.slice(0, 8)}`} />}
                  {x.phone && <ContactButtons phone={x.phone} name={x.owner_name} look="icons" />}
                </span>
                <details className="os-script" data-guide="os-script"><summary className="xs">Call script</summary>
                  <p className="small">{fillScript(script[x.stage] ?? '', { first_name: x.first_name, car: x.car, agent: b.agent })}</p></details>
              </li>))}</ul> : <p className="small muted">None.</p>}
          </section>))}
      </div>}
    </section>
  );
}
