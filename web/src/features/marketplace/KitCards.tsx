import type { ReactNode } from 'react';
import { Card } from '@/features/admin/ui';
import { CopyText } from '@/features/ads/CopyText';
import type { CarFacts, Rules } from '@/features/ads/listing';
import { photoUrl } from '@/lib/photo';
import type { Kit } from './kit';
import { replies } from './replies';
import { CopyValue } from './CopyValue';

// One car's Marketplace kit as cards (migration 0410; the copy variants of 0510): the fields in the vehicle form's order,
// the description, the tracked link, the photos in order with the ZIP, and the inbox replies. Admin's Marketplace page shows
// variant 1 (the owner's own); Sales's Marketing tab shows the person's variant.
export function KitCards({ c, k, rules, phone, aside, action, options, zipHref, variant }: {
  c: CarFacts; k: Kit; rules: Rules; phone: string | null; aside?: ReactNode;
  /** the car picker's form action (#kit is added) */ action: string;
  options: Array<{ id: string; label: string }>; zipHref: string | null; variant?: number;
}) {
  const rs = replies(c, rules, k.link, phone);
  return (<>
    <Card id="kit" title={`Kit: ${c.name}${c.car_code ? ` (${c.car_code})` : ''}${variant && variant > 1 ? `, variant ${variant}` : ''}`} testId="mp-kit" aside={aside}>
      <form method="get" action={`${action}#kit`} className="mp-pick">
        <label className="label" htmlFor="mp-car">Car</label>
        <select className="select" id="mp-car" name="car" defaultValue={c.vehicle_id} data-testid="mp-car">
          {options.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
        </select>
        <button className="btn btn--ghost btn--sm" type="submit">Show</button>
      </form>
      {k.blockers.length > 0 && <p className="small mp-warn" data-testid="mp-blockers"><b>Do not post yet:</b> {k.blockers.join('. ')}.</p>}
      {k.warnings.length > 0 && <ul className="small muted" data-testid="mp-warnings">{k.warnings.map((w) => <li key={w}>{w}</li>)}</ul>}
      <p className="small muted">facebook.com/marketplace/create/vehicle asks for these, in this order. Marketplace titles a vehicle Year Make Model by itself.</p>
      <dl className="mp-fields" data-testid="mp-fields">
        {k.fields.map((f) => <div key={f.label}><dt>{f.label}</dt><dd><span className="mp-val">{f.value || <span className="muted">{f.note}</span>}{f.value && f.note ? <span className="mp-note">{f.note}</span> : null}</span><CopyValue value={f.value} label={f.label} /></dd></div>)}
      </dl>
      <div className="stack">
        <CopyText label="Description" value={k.description} rows={Math.min(18, k.description.split('\n').length + 2)} max={5000} testId="mp-description" />
        <CopyText label="Tracked link" value={k.link} testId="mp-link" />
        <details><summary className="small">The description without the link (if Facebook holds the listing back for the link)</summary><CopyText label="Description without the link" value={k.descriptionNoLink} rows={10} testId="mp-description-nolink" /></details>
      </div>
    </Card>
    <Card title={`Photos, in this order (${k.photos.length} of 10)`} testId="mp-photos" aside={k.photos.length && zipHref ? <a className="btn btn--primary btn--sm" href={zipHref} download data-testid="mp-zip">Download the photos (ZIP)</a> : null}>
      {k.photos.length === 0 ? <p className="small muted">No real photos yet.</p> : (
        <ol className="mp-photos">{k.photos.map((p, i) => (
          <li key={p.path}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={photoUrl(p.path)} alt={p.alt || `${c.name}, photo ${i + 1}`} loading="lazy" />
            <span className="small"><b>{i + 1}.</b> {i === 0 ? 'Cover' : p.label ?? p.shot ?? 'Photo'}</span>
          </li>))}
        </ol>)}
      <p className="small muted">The ZIP names them 01 to {String(k.photos.length).padStart(2, '0')}: add them in that order, the first is the cover.</p>
    </Card>
    <Card title="Inbox replies for this car" testId="mp-replies">
      <p className="small muted">Every reply ends on the next step: request on carmacars.ca, or send a number for a call. Log each number.</p>
      <div className="mp-replies">{rs.map((r) => (
        <details key={r.key} className="mp-reply" data-testid={`mp-reply-${r.key}`}>
          <summary><b>{r.label}</b> <span className="small muted">{r.when}</span></summary>
          <CopyText label={`${r.label} reply`} value={r.text} rows={Math.min(8, r.text.split('\n').length + 3)} />
        </details>))}
      </div>
    </Card>
  </>);
}
