import qrcode from 'qrcode-generator';
import './incident-cards.css';
import { carTitle, reportPath, slipKind, steps, type CardCar, type CardData } from './model';

// Release 34 (section B): the printable incident card. Letter paper, two cards a page, crop marks at the corners of each
// card, a card 7.5 x 4.75 inches (fits a visor pocket or the glovebox). The page's own print rules hide the portal around it.
function Qr({ text }: { text: string }) {
  const qr = qrcode(0, 'M'); qr.addData(text); qr.make();
  return <div className="ic-qr" role="img" aria-label="QR code: report it in the app" dangerouslySetInnerHTML={{ __html: qr.createSvgTag({ cellSize: 3, margin: 1, scalable: true }) }} />;
}

function Card({ car, d, site, docBase }: { car: CardCar; d: CardData; site: string; docBase: string }) {
  const p = d.policy;
  const slip = p?.slip_document_id ? slipKind(p.slip_mime) : null;
  return (
    <article className="ic-card" data-testid="incident-card" aria-label={`Incident card for ${carTitle(car)}`}>
      <i className="ic-crop ic-crop--tl" aria-hidden="true" /><i className="ic-crop ic-crop--tr" aria-hidden="true" /><i className="ic-crop ic-crop--bl" aria-hidden="true" /><i className="ic-crop ic-crop--br" aria-hidden="true" />
      <header className="ic-head">
        <b className="ic-brand">{d.company.trade_name}</b>
        <span className="ic-car" data-testid="incident-card-car"><b>{carTitle(car)}</b> · Plate {car.plate ?? 'n/a'} · VIN {car.vin ?? 'n/a'}</span>
      </header>
      <div className="ic-body">
        <section className="ic-steps">
          <h2>In an accident or breakdown</h2>
          <ol>{steps(d).map((s) => <li key={s}>{s}</li>)}</ol>
          <div className="ic-report"><Qr text={`${site}${reportPath}`} /><span>Scan to report it in the app<br /><small>{site.replace(/^https?:\/\//, '')}{reportPath}</small></span></div>
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

export function IncidentCards({ data, site, docBase }: { data: CardData; site: string; docBase: string }) {
  // two cards a Letter page
  const pages: CardCar[][] = [];
  for (let i = 0; i < data.cars.length; i += 2) pages.push(data.cars.slice(i, i + 2));
  return (
    <div className="ic-sheets" data-testid="incident-sheets">
      {pages.map((pair, i) => <div className="ic-sheet" key={i}>{pair.map((c) => <Card key={c.vehicle_id} car={c} d={data} site={site} docBase={docBase} />)}</div>)}
    </div>
  );
}
