import { Fragment, type ReactNode } from 'react';
import type { Block } from './model';

// The agreement on screen: the same blocks as the PDF, as HTML sections for reading on a phone.
function inline(s: string): ReactNode {
  // two spaces separate the parts of a summary value (name, date of birth, address...): one per line on screen
  const parts = s.split(/ {2,}/);
  if (parts.length > 1) return parts.map((p, i) => <Fragment key={i}>{i > 0 && <br />}{inline(p)}</Fragment>);
  return s.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map((p, i) => (p.startsWith('**') ? <strong key={i}>{p.slice(2, -2)}</strong> : <Fragment key={i}>{p}</Fragment>));
}

export function AgreementView({ blocks, id = 'agreement', label = 'Rental agreement' }: { blocks: Block[]; id?: string; label?: string }) {
  let part = 0;
  return (
    <article className="agreement prose" id={id} aria-label={label}>
      {blocks.map((b, i) => {
        switch (b.t) {
          case 'title': return <h2 key={i} className="d3">{b.text}</h2>;
          case 'h2': part++; return <h3 key={i} className="d4 agreement__part" id={`${id}-part-${part}`}>{b.text}</h3>;
          case 'h3': return <h4 key={i} className="agreement__sec">{inline(b.text)}</h4>;
          case 'p': return <p key={i}>{inline(b.text)}</p>;
          case 'ul': return <ul key={i}>{b.items.map((it, k) => <li key={k}>{inline(it)}</li>)}</ul>;
          case 'ol': return <ol key={i}>{b.items.map((it, k) => <li key={k}>{inline(it)}</li>)}</ol>;
          case 'table':
            return (
              <div key={i} className="table-scroll" tabIndex={0} role="region" aria-label={b.head.join(' and ')}>
                <table className={`data${b.kv ? ' data--kv' : ''}`}>
                  <thead><tr>{b.head.map((h, k) => <th key={k} scope="col">{h}</th>)}</tr></thead>
                  <tbody>{b.rows.map((r, k) => <tr key={k}>{r.map((c, j) => (j === 0 ? <th key={j} scope="row">{inline(c)}</th> : <td key={j}>{inline(c)}</td>))}</tr>)}</tbody>
                </table>
              </div>
            );
          case 'signatures':
            return (
              <div key={i} className="table-scroll" tabIndex={0} role="region" aria-label="Signatures">
                <table className="data">
                  <thead><tr><th scope="col">Party</th><th scope="col">Name</th><th scope="col">Electronic signature</th><th scope="col">Date and time</th></tr></thead>
                  <tbody>{b.rows.map((r, k) => <tr key={k}><th scope="row">{r.party}</th><td>{r.name}</td><td>{r.signature}</td><td>{r.when}</td></tr>)}</tbody>
                </table>
              </div>
            );
        }
      })}
    </article>
  );
}
