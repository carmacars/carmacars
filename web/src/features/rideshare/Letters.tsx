import { when } from '@/features/agreement/model';
import { carWords, type LetterKind, type RideshareFacts } from './model';

// r35a (1303): the letters rideshare and delivery platforms ask for, on the company letterhead. They name only the company
// (the Program settings' legal name), never the car's owner. Printable: one letter a page.
const day = (iso: string | null | undefined) => (iso ? when(iso.length === 10 ? `${iso}T12:00:00Z` : iso, false) : '');

function Letterhead({ f }: { f: RideshareFacts }) {
  return (
    <header className="rs-head">
      <p className="rs-co"><b>{f.company.legal_name}</b>{f.company.trade_name ? <> (operating as {f.company.trade_name})</> : null}</p>
      <p className="small">{[f.company.address, f.company.phone, f.company.email].filter(Boolean).join(' · ')}</p>
      <p className="small">{day(f.issued_at)} · Rental {f.booking_number}</p>
    </header>
  );
}

function Signoff({ f }: { f: RideshareFacts }) {
  return <p className="rs-sign">{f.company.legal_name}<br /><span className="small">Rental operations{f.company.phone ? `, ${f.company.phone}` : ''}</span></p>;
}

export function Letter({ f, kind, platforms }: { f: RideshareFacts; kind: LetterKind; platforms: string }) {
  const car = carWords(f.car);
  const period = `${when(f.pickup_at)} to ${when(f.return_at)}`;
  const drivers = f.drivers.length ? f.drivers.join(', ') : f.renter ?? '';
  return (
    <article className="rs-letter" data-testid={`rideshare-letter-${kind}`}>
      <Letterhead f={f} />
      <p>To whom it may concern{platforms ? ` at ${platforms}` : ''},</p>
      {kind === 'vehicle' ? <>
        <h2 className="d4">Vehicle registration and ownership</h2>
        <p>The vehicle below is in the care, custody and control of <b>{f.company.legal_name}</b>, which rents it to <b>{f.renter}</b> under rental agreement {f.booking_number} for {period}.</p>
        <dl className="pt-dl small">
          <div><dt>Vehicle</dt><dd>{car}</dd></div>
          <div><dt>Plate</dt><dd>{f.car.plate ?? ''} (Ontario)</dd></div>
          <div><dt>VIN</dt><dd>{f.car.vin ?? ''}</dd></div>
          <div><dt>Authorized drivers</dt><dd>{drivers}</dd></div>
        </dl>
        <p>{f.company.legal_name} authorizes the drivers named above to use this vehicle on {platforms || 'the platform'} for the rental period. Questions about the vehicle go to {f.company.legal_name}{f.company.phone ? ` at ${f.company.phone}` : ''}{f.company.email ? ` or ${f.company.email}` : ''}.</p>
      </> : <>
        <h2 className="d4">Proof of insurance and coverage</h2>
        <p>The vehicle {car}, plate {f.car.plate ?? ''}, VIN {f.car.vin ?? ''}, is rented by <b>{f.company.legal_name}</b> to <b>{f.renter}</b> under rental agreement {f.booking_number} for {period}.</p>
        {f.fleet_policy ? <dl className="pt-dl small">
          <div><dt>Fleet automobile policy</dt><dd>{f.fleet_policy.insurer_name}, policy {f.fleet_policy.policy_number}</dd></div>
          <div><dt>Named insured</dt><dd>{f.company.legal_name}</dd></div>
          <div><dt>In force</dt><dd>{day(f.fleet_policy.effective_on)} to {day(f.fleet_policy.expires_on)}</dd></div>
        </dl> : <p className="small">The vehicle is insured under {f.company.legal_name}&apos;s fleet automobile policy (third-party liability as Ontario law requires).</p>}
        <p>Coverage for damage to the vehicle during this rental: <b>{f.coverage_card?.short ?? 'as set out in the rental agreement'}</b>{f.coverage?.kind === 'own_policy' && f.coverage.insurer_name ? ` (${f.coverage.insurer_name}${f.coverage.policy_expiry ? `, valid to ${day(f.coverage.policy_expiry)}` : ''})` : ''}{f.coverage?.kind === 'plan' && f.coverage.plan_provider ? ` (${f.coverage.plan_provider})` : ''}. {f.coverage_card?.proof_words ?? ''}.</p>
        <p className="small">This letter confirms the rental and its coverage for the platform&apos;s records. The rental agreement {f.booking_number} sets out the terms.</p>
      </>}
      <Signoff f={f} />
    </article>
  );
}

export function Letters({ f }: { f: RideshareFacts }) {
  const latest = f.requests[0];
  const platforms = latest ? latest.labels.join(', ') : '';
  return <div className="rs-letters">{(['coverage', 'vehicle'] as const).map((k) => <Letter key={k} f={f} kind={k} platforms={platforms} />)}</div>;
}
