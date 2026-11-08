import qrcode from 'qrcode-generator';
import Link from '@/components/Link';
import '@/features/incident-cards/incident-cards.css';
import { reportPath } from '@/features/incident-cards/model';
import { accidentSteps, coverageBlock, type AccidentCardData } from './model';

// The renter's accident card of one booking (release 35, migration 0910): the r34 card's steps and the coverage this
// booking uses (their own policy, their card coverage, or the Protection Plan), never the fleet policy. The same card on the
// renter's booking page, its printable page and the staff booking page; printed on Letter paper at the card's size.
function Qr({ text }: { text: string }) {
  const qr = qrcode(0, 'M'); qr.addData(text); qr.make();
  return <div className="ic-qr" role="img" aria-label="QR code: report it in the app" dangerouslySetInnerHTML={{ __html: qr.createSvgTag({ cellSize: 3, margin: 1, scalable: true }) }} />;
}

export function AccidentCard({ d, site }: { d: AccidentCardData; site: string }) {
  const c = coverageBlock(d.coverage);
  const car = [d.car.year, d.car.make, d.car.model].filter(Boolean).join(' ') || 'Car';
  return (
    <article className="ic-card ic-card--booking" data-testid="accident-card" aria-label={`Accident card for booking ${d.booking_number}`}>
      <i className="ic-crop ic-crop--tl" aria-hidden="true" /><i className="ic-crop ic-crop--tr" aria-hidden="true" /><i className="ic-crop ic-crop--bl" aria-hidden="true" /><i className="ic-crop ic-crop--br" aria-hidden="true" />
      <header className="ic-head">
        <b className="ic-brand">{d.company.trade_name}</b>
        <span className="ic-car"><b>{car}</b> · Plate {d.car.plate ?? 'n/a'} · Booking {d.booking_number}</span>
      </header>
      <div className="ic-body">
        <section className="ic-steps">
          <h2>After an accident</h2>
          <ol>{accidentSteps(d).map((s) => <li key={s}>{s}</li>)}</ol>
          <div className="ic-report"><Qr text={`${site}${reportPath}`} /><span>Scan to report it in the app<br /><small>{site.replace(/^https?:\/\//, '')}{reportPath}</small></span></div>
        </section>
        <section className="ic-slip" aria-label="Your coverage" data-testid="accident-card-coverage">
          <h2>{c.title}</h2>
          <p className="ic-none">{c.lead}</p>
          {c.rows.length > 0 && <dl className="ic-dl">{c.rows.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>}
          {d.renter && <p className="ic-none"><small>Renter: {d.renter}. VIN {d.car.vin ?? 'n/a'}</small></p>}
        </section>
      </div>
    </article>
  );
}

/** The card on a Letter sheet, for printing. */
export function AccidentSheet({ d, site }: { d: AccidentCardData; site: string }) {
  return <div className="ic-sheets" data-testid="accident-sheet"><div className="ic-sheet"><AccidentCard d={d} site={site} /></div></div>;
}

/** The card's content for the screen (the booking pages), at any width. */
export function AccidentSummary({ d, printHref }: { d: AccidentCardData; printHref?: string }) {
  const c = coverageBlock(d.coverage);
  return (
    <div className="stack" data-testid="accident-summary">
      <ol className="small">{accidentSteps(d).map((s) => <li key={s}>{s}</li>)}</ol>
      <div className="stack" data-testid="accident-summary-coverage">
        <p><b>{c.title}</b>{d.coverage.kind !== 'none' && !d.coverage.confirmed ? ' (waiting for our check)' : ''}</p>
        <p className="small">{c.lead}</p>
        {c.rows.length > 0 && <dl className="pt-dl">{c.rows.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>}
      </div>
      {printHref && <p><Link prefetch={false} className="btn btn--ghost btn--sm" href={printHref} data-testid="accident-print-link">Open the card to print</Link></p>}
    </div>
  );
}
