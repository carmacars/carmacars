import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { InsurerConfirm } from '@/features/admin/InsurerConfirm';
import '@/features/onboarding/onboarding.css';
import './owner-stages.css';
import { AppointmentForm, VisitedForm } from './OwnerStageForms';
import { actionFor, daysWords, fillScript, hrefFor, progressLine, STATE_WORDS, waitsOn, type Stage, type StageAction, type Stages, type Track, type Viewer } from './model';

// The owner pipeline (r50, 4511): one stage tracker per owner and car, the same in the owner portal, Admin and the staff
// portals (Sales, customer service, Fleet). Each car: its route, every stage done or not, and the current one with its one
// next action for the right person, what to bring, where to go, the expected time and the blockers in plain words.
// Staff nudge the owner and read the call script; an Admin overrides or advances a stage (kept in the audit log).

const STEP_CLASS: Record<Stage['state'], string> = { done: 'done', current: 'waiting', todo: 'blocked', not_needed: 'not_needed' };

function OwnerAction({ t, s, a, finder }: { t: Track; s: Stage; a: StageAction; finder: string }) {
  if (a.op === 'appointment') return <AppointmentForm vehicleId={t.vehicle_id} finderUrl={a.href ?? finder} />;
  if (a.op === 'visited') return <VisitedForm vehicleId={t.vehicle_id} payer={t.fees_payer} />;
  if (!a.href) return <p className="small" data-testid="os-wait">{a.label}</p>;
  return a.external
    ? <p><a className="btn btn--primary btn--lg os-cta" href={a.href} target="_blank" rel="noopener noreferrer" data-testid="os-cta" data-guide="os-cta">{a.label}{a.provider ? ` with ${a.provider}` : ''}</a></p>
    : <p><Link prefetch={false} className="btn btn--primary btn--lg os-cta" href={a.href} data-testid="os-cta" data-guide="os-cta">{s.code === 'documents' ? 'Upload now' : a.label}</Link></p>;
}

function StaffAction({ t, a, base, refresh, viewer }: { t: Track; a: StageAction; base: '/admin' | '/staff'; refresh: string[]; viewer: Viewer }) {
  const p = { vehicle_id: t.vehicle_id };
  if (a.op === 'nudge') return null; // the Nudge button is always there for staff
  if (a.op === 'appointment') return <Act action="owner_stage_do" payload={{ ...p, op: 'appointment' }} label={a.label} variant="primary" refresh={refresh} done="Appointment saved." testId="os-staff-appointment"
    fields={[{ name: 'at', label: 'Date and time', type: 'datetime', required: true }, { name: 'place', label: 'ServiceOntario centre', type: 'text', required: true }]} />;
  if (a.op === 'visited') return viewer === 'sales' ? null : <Act action="owner_stage_do" payload={{ ...p, op: 'visited' }} label={a.label} variant="primary" refresh={refresh} done="Recorded: the transfer is filed." testId="os-staff-visited"
    fields={[{ name: 'fees_paid', label: `The fees are paid (${t.fees_payer})`, type: 'bool', value: false }, { name: 'fees_note', label: 'Fees note (receipt, amount)', type: 'text' }]} />;
  if (a.op === 'inspected') return <Act action="owner_stage_do" payload={{ ...p, op: 'inspected' }} label={a.label} variant="primary" refresh={refresh} done="Inspection recorded." testId="os-inspected"
    fields={[{ name: 'note', label: 'What you found (damage, tires, warning lights)', type: 'textarea' }]} />;
  if (a.op === 'insure') return viewer === 'sales' ? null : <InsurerConfirm vehicleId={t.vehicle_id} name={t.name} refresh={refresh} label="Insurer confirmed" testId="os-insure" />;
  const href = hrefFor(a.href, base);
  return href ? <Link prefetch={false} className="btn btn--primary btn--sm" href={href} data-testid="os-staff-cta">{a.label}</Link> : <span className="small">{a.label}</span>;
}

function Car({ t, d, base, refresh, agent }: { t: Track; d: Stages; base: '/admin' | '/staff' | '/owner'; refresh: string[]; agent: string }) {
  const c = t.current;
  const staffBase = base === '/owner' ? '/staff' : base;
  const a = c ? actionFor(c, d.viewer) : null;
  const owner = d.viewer === 'owner';
  const missing = c?.items.filter((i) => !i.done).map((i) => i.label).join(', ');
  return (
    <div className="os-car stack" data-testid="os-car" data-vehicle={t.vehicle_id} data-stage={t.stage ?? 'done'} data-actor={t.actor ?? ''}>
      <div className="os-car__head">
        <h3 className="d5">{t.name}{t.plate ? <span className="small muted"> {t.plate}</span> : null}</h3>
        <span className="badge badge--outline os-route" data-testid="os-route" data-route={t.route}>{t.route_label}</span>
      </div>
      <p className="small" data-testid="os-progress">{progressLine(t, d.viewer)}{c && t.days_in_stage !== null ? ` In this step ${daysWords(t.days_in_stage)}.` : ''}</p>
      {c && <section className={`os-now ${c.actor === 'owner' && owner ? 'os-now--mine' : ''}`} aria-label={`Now: ${c.label}`} data-testid="os-now" data-guide="os-now" data-step={c.code}>
        <p className="pt-kicker os-kicker">{waitsOn(c.actor, d.viewer)}</p>
        <h4 className="d4">{c.label}</h4>
        {c.blockers.length > 0 && <div className="alert alert--warn" role="status" data-testid="os-blockers"><span className="alert__title">First</span>
          <ul className="os-blockers">{c.blockers.map((b) => <li key={b}>{b}</li>)}</ul></div>}
        {owner && a && <OwnerAction t={t} s={c} a={a} finder={d.finder_url} />}
        {owner && !a && <p className="small" data-testid="os-wait">{c.owner_text}</p>}
        {!owner && <p className="small"><b>Next:</b> {c.actor === 'owner' ? c.action?.owner?.label ?? c.owner_text : c.staff_text}</p>}
        {!owner && a && <div className="os-actions"><StaffAction t={t} a={a} base={staffBase} refresh={refresh} viewer={d.viewer} /></div>}
        <dl className="os-facts">
          {c.bring && <><dt>Bring</dt><dd>{c.bring}</dd></>}
          {c.where && <><dt>Where</dt><dd>{c.where}{c.where_url && <> <a className="link" href={c.where_url} target="_blank" rel="noopener noreferrer" data-testid="os-where">Find a centre</a></>}</dd></>}
          <dt>Expected</dt><dd>{c.expected}</dd>
        </dl>
        {c.items.length > 0 && <ul className="os-items" aria-label={`What ${c.label} needs`}>{c.items.map((i) => (
          <li key={i.label} className={i.done ? 'os-item--done' : ''} data-done={i.done ? 'yes' : 'no'}><span aria-hidden="true">{i.done ? '✓' : '○'}</span> {i.label}{i.state === 'waiting' ? ' (being checked)' : i.state === 'rejected' ? ' (not accepted)' : ''}</li>))}</ul>}
        {!owner && <div className="os-actions">
          {d.can_nudge && c.actor === 'owner' && <Act action="owner_stage_do" payload={{ vehicle_id: t.vehicle_id, op: 'nudge' }} label="Nudge: email and text" refresh={refresh}
            done="Reminder sent: email and text." testId="os-nudge" />}
          {d.can_record && t.stage === 'transfer' && (d.viewer === 'admin' || d.viewer === 'staff') && <Act action="owner_stage_do" payload={{ vehicle_id: t.vehicle_id, op: 'needs' }} label="UVIP or certificate not needed?" variant="quiet" refresh={refresh} done="Saved."
            testId="os-needs" fields={[{ name: 'uvip_needed', label: 'Needs the Used Vehicle Information Package', type: 'bool', value: t.uvip_needed }, { name: 'ssc_needed', label: 'Needs a Safety Standards Certificate', type: 'bool', value: t.ssc_needed }, { name: 'note', label: 'Why', type: 'text' }]} />}
          {d.can_override && <Act action="owner_stage_do" payload={{ vehicle_id: t.vehicle_id, op: 'advance' }} label="Advance this step" variant="quiet" refresh={refresh} done="Advanced. Kept in the audit log."
            testId="os-advance" fields={[{ name: 'note', label: 'Why (kept in the audit log)', type: 'text', required: true }]} />}
        </div>}
        {!owner && <details className="os-script" data-testid="os-script" data-guide="os-script"><summary className="small">Call script</summary>
          <p className="small">{fillScript(c.call_script, { first_name: t.owner_name.split(' ')[0] ?? '', car: t.name, agent, missing })}</p></details>}
      </section>}
      <ol className="ob-steps os-steps" aria-label={`Onboarding steps of the ${t.name}`}>
        {t.stages.map((s, i) => (
          <li key={s.code} className={`ob-step ob-step--${STEP_CLASS[s.state]}`} data-testid="os-step" data-step={s.code} data-state={s.state} aria-current={s.state === 'current' ? 'step' : undefined}>
            <span className="ob-step__mark" aria-hidden="true" />
            <span className="ob-step__text"><b className="ob-step__label">{i + 1}. {s.label}<span className="vh">: {STATE_WORDS[s.state]}</span></b>
              {s.override && <span className="ob-step__why">Set by an Admin: {s.override.note}</span>}</span>
            <span className="ob-step__act"><span className={`badge ${s.state === 'current' ? '' : 'badge--outline'}`}>{STATE_WORDS[s.state]}</span></span>
          </li>))}
      </ol>
      {d.can_override && <Act action="owner_stage_do" payload={{ vehicle_id: t.vehicle_id, op: 'set' }} label="Override a step" variant="quiet" refresh={refresh} done="Saved. Kept in the audit log." testId="os-override"
        fields={[{ name: 'stage', label: 'Step', type: 'select', required: true, options: t.stages.map((s) => [s.code, s.label] as [string, string]) },
          { name: 'status', label: 'Set it to', type: 'select', options: [['done', 'Done'], ['not_needed', 'Not needed'], ['open', 'Open again'], ['', 'Follow the records again']] },
          { name: 'note', label: 'Why (kept in the audit log)', type: 'text', required: true }]} />}
    </div>
  );
}

export function StageTracker({ data, only, base, refresh, title = 'Onboarding steps' }: { data: Stages | null; only?: string; base: '/admin' | '/staff' | '/owner'; refresh: string[]; title?: string }) {
  if (!data) return null;
  const cars = data.cars.filter((c) => !only || c.vehicle_id === only);
  if (!cars.length) return null;
  return (
    <section className="pt-card pt-card--next stack os" id="stages" aria-labelledby="os-h" data-testid="owner-stages" data-guide="owner-stages">
      <div className="pt-card__head"><h2 className="d4" id="os-h">{title}</h2></div>
      <p className="small muted">{data.viewer === 'owner' ? 'Each car, step by step: the one thing to do now, what to bring and how long it takes.'
        : `Each car's step, whose turn it is and the one next action. A step waiting ${data.stall_days} days alerts the Admins and the salesperson.`}</p>
      {cars.map((t) => <Car key={t.vehicle_id} t={t} d={data} base={base} refresh={refresh} agent={data.agent ?? 'CarmaCars'} />)}
    </section>
  );
}
