import qrcode from 'qrcode-generator';
import './incident-cards.css';
import { COVERAGE_OPTIONS, CARDS_PER_SHEET, coverageLead, reportPath, slipKind, steps, type CardData } from './model';

// The printable incident card (release 34 section B; one generic card since 1150): the same card for every car. Letter
// paper, two cards a page, crop marks at the corners of each card, a card 7.5 x 4.75 inches (fits a visor pocket or the
// glovebox). The steps, what to show for each of the three coverage options, the fleet insurance slip, and one QR code to
// /incident (the renter's digital card). Never a car, a plate, a renter, a booking or an amount. The page's own print rules
// hide the portal around it.
function Qr({ text }: { text: string }) {
  const qr = qrcode(0, 'M'); qr.addData(text); qr.make();
  return <div className="ic-qr" role="img" aria-label="QR code: your digital incident card" dangerouslySetInnerHTML={{ __html: qr.createSvgTag({ cellSize: 3, margin: 1, scalable: true }) }} />;
}

function Card({ d, site, docBase }: { d: CardData; site: string; docBase: string }) {
  const p = d.policy;
  const slip = p?.slip_document_id ? slipKind(p.slip_mime) : null;
  return (
    <article className="ic-card ic-card--generic" data-testid="incident-card" aria-label="Incident card">
      <i className="ic-crop ic-crop--tl" aria-hidden="true" /><i className="ic-crop ic-crop--tr" aria-hidden="true" /><i className="ic-crop ic-crop--bl" aria-hidden="true" /><i className="ic-crop ic-crop--br" aria-hidden="true" />
      <header className="ic-head">
        <b className="ic-brand">{d.company.trade_name}</b>
        <span className="ic-car">Incident card: keep it in the car</span>
      </header>
      <div className="ic-body ic-body--3">
        <section className="ic-steps">
          <h2>In an accident or breakdown</h2>
          <ol>{steps(d).map((s) => <li key={s}>{s}</li>)}</ol>
          <div className="ic-report"><Qr text={`${site}${reportPath}`} /><span>Scan for your digital card: your coverage, booking and contract, and Report a problem<br /><small>{site.replace(/^https?:\/\//, '')}{reportPath}</small></span></div>
        </section>
        <section className="ic-show" aria-label="What to show" data-testid="incident-card-options">
          <h2>What to show</h2>
          <p className="ic-none"><small>{coverageLead}</small></p>
          <ul>{COVERAGE_OPTIONS.map((o) => <li key={o.option} data-testid={`incident-card-option-${o.option}`}><b>{o.title}</b><br />{o.show}</li>)}</ul>
        </section>
        <section className="ic-slip" aria-label="Fleet insurance slip" data-testid="incident-card-slip">
          <h2>Insurance slip</h2>
          {!p ? <p className="ic-none">Insurance slip: ask {d.company.trade_name}.</p>
            // eslint-disable-next-line @next/next/no-img-element -- private signed document on a printed card
            : slip === 'image' ? <img className="ic-slip__file" src={`${docBase}/${p.slip_document_id}`} alt={`Insurance slip, policy ${p.policy_number}`} />
            : slip === 'pdf' ? <object className="ic-slip__file" data={`${docBase}/${p.slip_document_id}#toolbar=0&view=FitH`} type="application/pdf" aria-label="Insurance slip">
                <SlipFields p={p} />
              </object>
            : <SlipFields p={p} />}
        </section>
      </div>
    </article>
  );
}

function SlipFields({ p }: { p: NonNullable<CardData['policy']> }) {
  return (
    <dl className="ic-dl">
      <div><dt>Insurer</dt><dd>{p.insurer_name}</dd></div>
      <div><dt>Policy no.</dt><dd>{p.policy_number}</dd></div>
      <div><dt>Effective</dt><dd>{p.effective_on}</dd></div>
      <div><dt>Expires</dt><dd>{p.expires_on}{p.expired ? ' (expired)' : ''}</dd></div>
      <div><dt>Named insured</dt><dd>{p.named_insured}</dd></div>
      {p.claims_phone && <div><dt>Claims</dt><dd>{p.claims_phone}</dd></div>}
    </dl>
  );
}

/** One Letter sheet of the generic card (print as many copies as there are cars). */
export function IncidentCards({ data, site, docBase }: { data: CardData; site: string; docBase: string }) {
  return (
    <div className="ic-sheets" data-testid="incident-sheets">
      <div className="ic-sheet">{Array.from({ length: CARDS_PER_SHEET }, (_, i) => <Card key={i} d={data} site={site} docBase={docBase} />)}</div>
    </div>
  );
}
