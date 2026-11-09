import Link from '@/components/Link';
import { Faq } from '@/components/Faq';
import type { DepthText } from './depth';

// The depth sections on a page (release 35, part M): headings, paragraphs, a table and links, rendered on the server
// with no client code. The questions are rendered here only when the page has no question list of its own (the
// caller merges them otherwise, and puts them in the FAQPage JSON-LD). The sources are listed under the sections.
export function DepthSections({ d, look = 'hub', faq = false }: { d: DepthText; look?: 'hub' | 'vehicle'; faq?: boolean }) {
  if (!d.sections.length) return null;
  const sec = look === 'hub' ? 'car-sec landing__sec' : 'vp-sec';
  const h = look === 'hub' ? 'd2' : 'd3';
  return (
    <div className="depth" data-testid="depth" data-depth-words={d.words}>
      {d.sections.map((s) => (
        <section key={s.id} className={sec} aria-labelledby={`h-depth-${s.id}`} data-depth-section={s.id}>
          <h2 className={h} id={`h-depth-${s.id}`}>{s.heading}</h2>
          {s.paras.map((p, i) => <p key={i} className="measure">{p}</p>)}
          {s.table && (
            <div className="table-scroll" tabIndex={0} role="region" aria-label={s.heading}>
              <table className="data data--min"><thead><tr>{s.table.head.map((x) => <th key={x} scope="col">{x}</th>)}</tr></thead>
                <tbody>{s.table.rows.map((r, i) => <tr key={i}>{r.map((x, k) => (k === 0 ? <th key={k} scope="row">{x}</th> : <td key={k}>{x}</td>))}</tr>)}</tbody></table>
            </div>
          )}
          {s.links && s.links.length > 0 && <nav aria-label={s.heading}><ul className="linklist landing__cols">{s.links.map((l) => <li key={l.href}><Link prefetch={false} className="link" href={l.href}>{l.label}</Link></li>)}</ul></nav>}
        </section>
      ))}
      {faq && d.faq.length > 0 && <section className={sec} aria-labelledby="h-depth-faq"><h2 className={h} id="h-depth-faq">Questions</h2><Faq items={d.faq} /></section>}
      {d.attributions.length > 0 && <p className="xs muted" data-testid="depth-sources">Sources: {d.attributions.join('; ')}.</p>}
    </div>
  );
}
