import Link from 'next/link';
import { pct, type PathRow } from './model';

// The person's paths (Release 21b, item 9): each section with its state: passed, open, or waiting for the one before it.
export function Paths({ paths, base }: { paths: PathRow[]; base: string }) {
  if (!paths.length) return <p className="muted">No path yet: an Admin gives you a staff function first.</p>;
  return (
    <div className="stack-lg">
      {paths.map((p) => {
        const done = p.sections.filter((s) => s.passed).length;
        return (
          <section key={p.code} className="pt-card stack" aria-labelledby={`ac-p-${p.code}`} data-testid={`path-${p.code}`}>
            <h2 className="d4" id={`ac-p-${p.code}`}>{p.title} {p.passed && <span className="ac-badge ac-badge--ok">Passed</span>}</h2>
            <p className="small muted">{p.blurb} {done} of {p.sections.length} sections passed.</p>
            <ol className="ac-sections">
              {p.sections.map((s) => (
                <li key={s.id} data-testid={`section-${s.slug}`}>
                  <span>{s.open ? <Link prefetch={false} className="link" href={`${base}/${p.code}/${s.slug}`}>{s.title}</Link> : <span>{s.title}</span>}
                    <span className="small muted"> · {s.lessons} lessons, {s.questions} questions{s.best_bps !== null ? ` · best ${pct(s.best_bps)}` : ''}</span></span>
                  <span className={`ac-badge${s.passed ? ' ac-badge--ok' : s.open ? '' : ' ac-badge--locked'}`}>{s.passed ? 'Passed' : s.open ? (s.unlocked_early ? 'Opened by an Admin' : 'Open') : 'Pass the one before'}</span>
                </li>
              ))}
            </ol>
          </section>
        );
      })}
    </div>
  );
}
