'use client';
import { useMemo, useState } from 'react';
import { checkedOn, COVERAGE_HINT, COVERAGE_LABEL, daysLimit, filterCards, NO_FILTER, valueLimit, type CardFilter, type CardRow } from './cards';

// The searchable list of /credit-card-rental-coverage and /va/card-coverage (0131). Every row is rendered by the server
// too, so the list reads without JavaScript; the search and filters only narrow it.
export function CardTable({ rows }: { rows: CardRow[] }) {
  const [f, setF] = useState<CardFilter>(NO_FILTER);
  const shown = useMemo(() => filterCards(rows, f), [rows, f]);
  const set = <K extends keyof CardFilter>(k: K, v: CardFilter[K]) => setF((x) => ({ ...x, [k]: v }));
  return (
    <div className="stack cc-box" data-testid="card-coverage">
      <div className="cc-filters" role="search" aria-label="Filter the cards">
        <div className="field cc-filters__q">
          <label className="label" htmlFor="cc-q">Search</label>
          <input className="input" id="cc-q" type="search" placeholder="Bank or card, for example Aeroplan" autoComplete="off" value={f.q}
            onChange={(e) => set('q', e.target.value)} data-testid="card-coverage-q" />
        </div>
        <div className="field">
          <label className="label" htmlFor="cc-country">Issued in</label>
          <select className="select" id="cc-country" value={f.country} onChange={(e) => set('country', e.target.value as CardFilter['country'])} data-testid="card-coverage-country">
            <option value="all">Canada and the US</option><option value="CA">Canada</option><option value="US">United States</option>
          </select>
        </div>
        <div className="field">
          <label className="label" htmlFor="cc-value">Covers cars priced up to</label>
          <select className="select" id="cc-value" value={f.value} onChange={(e) => set('value', e.target.value as CardFilter['value'])} data-testid="card-coverage-value">
            <option value="any">Any limit</option><option value="65000">$65,000 or more</option><option value="85000">$85,000 or more</option><option value="100000">$100,000 or more</option>
          </select>
        </div>
        <label className="check cc-filters__check"><input type="checkbox" checked={f.primary} onChange={(e) => set('primary', e.target.checked)} data-testid="card-coverage-primary" /><span>Primary only</span></label>
      </div>
      <p className="small muted" aria-live="polite" data-testid="card-coverage-count">{shown.length === rows.length ? `${rows.length} cards` : `${shown.length} of ${rows.length} cards`}</p>
      <div className="table-scroll" tabIndex={0} role="region" aria-label="Credit cards and their rental car coverage">
        <table className="data cc-table">
          <thead><tr>
            <th scope="col">Card</th><th scope="col">Pays</th><th scope="col">Car value limit</th><th scope="col">Longest rental</th>
            <th scope="col">Key exclusions and conditions</th><th scope="col">Official guide</th><th scope="col">Last checked</th>
          </tr></thead>
          <tbody>
            {shown.map((c) => (
              <tr key={c.id} data-testid={`card-${c.issuer}-${c.card}`.toLowerCase().replace(/[^a-z0-9]+/g, '-')}>
                <th scope="row"><span className="cc-issuer">{c.issuer}{c.country === 'US' ? ' (US)' : ''}</span><span className="cc-card">{c.card}</span></th>
                <td><span title={COVERAGE_HINT[c.coverage]}>{COVERAGE_LABEL[c.coverage]}</span></td>
                <td className={c.max_msrp_cents ? 'num' : undefined}>{valueLimit(c)}</td>
                <td>{daysLimit(c)}</td>
                <td className="cc-ex">
                  {c.exclusions && <p><b>Excluded:</b> {c.exclusions}</p>}
                  {c.conditions && <p><b>To use it:</b> {c.conditions}</p>}
                  {c.car_sharing && <p><b>Car sharing:</b> {c.car_sharing}</p>}
                  {c.note && <p className="muted">{c.note}</p>}
                </td>
                <td>{c.guide_url ? <a className="link" href={c.guide_url} target="_blank" rel="noopener noreferrer">{c.issuer}&apos;s guide<span className="vh"> for the {c.card} (opens in a new tab)</span></a> : <span className="muted">Ask the issuer</span>}</td>
                <td>
                  <span className="cc-date">{checkedOn(c.last_checked)}</span>
                  <span className={`small cc-src${c.issuer_checked ? '' : ' muted'}`}>{c.issuer_checked ? 'In the issuer’s document' : <>Unverified{c.source_url ? <>: <a className="link" href={c.source_url} target="_blank" rel="noopener noreferrer">source</a></> : null}</>}</span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {!shown.length && <p className="muted" data-testid="card-coverage-none">No card matches. Clear the search or choose a lower limit.</p>}
    </div>
  );
}
