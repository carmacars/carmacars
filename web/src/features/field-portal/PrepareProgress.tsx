import { prepareWords, type PrepareProgressData } from './prepare';

// r35 UX (1107): the field staff's progress on preparing a rental, read only, for the office (Admin, Sales, customer service,
// Fleet, Finance) on the booking and on the car: each add-on with its quantity, ticked or not (who, when), and the pickup or
// delivery job with its status and field person.
export function PrepareProgress({ d, title = 'Prepare for the pickup', testId = 'prepare-progress' }: { d: PrepareProgressData | null; title?: string; testId?: string }) {
  if (!d) return null;
  const w = prepareWords(d);
  return (
    <section className="pt-card ad-card" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <div className="pt-card__head"><h2 className="d4" id={`${testId}-h`}>{title}</h2><span className={`chip${w.done ? ' chip--ok' : ''}`} data-testid={`${testId}-count`}>{w.count}</span></div>
      <p className="small">{w.job}</p>
      {d.items.length > 0 ? (
        <ul className="prep-list">{d.items.map((a) => (
          <li key={a.id} className={a.ticked ? 'is-done' : ''}>
            <span className="prep-list__mark" aria-hidden="true">{a.ticked ? '✓' : ''}</span>
            <span><b>{a.quantity > 1 ? `${a.quantity} x ` : ''}{a.name}</b>{a.note ? <small className="muted"> {a.note}</small> : null}
              <small className="muted">{a.ticked ? ` In the car${a.ticked_by ? `, ticked by ${a.ticked_by}` : ''}${a.ticked_at ? `, ${new Date(a.ticked_at).toLocaleString('en-CA', { timeZone: 'America/Toronto', dateStyle: 'medium', timeStyle: 'short' })}` : ''}` : ' Not ticked yet'}</small>
              <span className="vh">{a.ticked ? ', done' : ', to do'}</span></span>
          </li>))}</ul>
      ) : <p className="small muted">No add-ons to put in the car.</p>}
    </section>
  );
}
