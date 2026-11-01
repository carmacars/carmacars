import Link from 'next/link';
import type { ReactNode } from 'react';

// The first panel of each portal home (r27 portals): what the person needs to do or know right now, in one sentence,
// with the one button for it and the few next things beside it. Black, the admin revamp's dark band: the headline in the
// display face, the facts as figures that never wrap, one red button.
export interface NowFact { key: string; label: string; value: ReactNode; sub?: ReactNode; warn?: boolean; testId?: string }
export interface NowLink { key: string; label: string; href: string; primary?: boolean; testId?: string }

export function NowPanel({ kicker, headline, detail, actions = [], facts = [], extra, urgent = false, testId = 'now', titleId = 'now-h', children }: {
  kicker?: ReactNode; headline: ReactNode; detail?: ReactNode; actions?: NowLink[]; facts?: NowFact[]; extra?: ReactNode; urgent?: boolean; testId?: string; titleId?: string; children?: ReactNode;
}) {
  const ext = (h: string) => /^(tel:|mailto:|https?:)/.test(h);
  return (
    <section className={`now${urgent ? ' now--urgent' : ''}`} aria-labelledby={titleId} data-testid={testId}>
      <div className="now__text">
        {kicker && <p className="now__kicker">{kicker}</p>}
        <h2 className="now__title" id={titleId}>{headline}</h2>
        {detail && <p className="now__detail">{detail}</p>}
      </div>
      {facts.length > 0 && (
        <dl className="now__facts" style={{ ['--now-n' as string]: facts.length }}>
          {facts.map((f) => (
            <div key={f.key} className={`now__fact${f.warn ? ' is-warn' : ''}`}>
              <dt>{f.label}</dt><dd className="now__v" data-testid={f.testId}>{f.value}</dd>{f.sub && <dd className="now__s">{f.sub}</dd>}
            </div>
          ))}
        </dl>
      )}
      {(actions.length > 0 || extra) && (
        <div className="now__actions">
          {actions.map((a) => ext(a.href)
            ? <a key={a.key} className={`btn ${a.primary ? 'btn--primary' : 'now__btn'}`} href={a.href} data-testid={a.testId}>{a.label}</a>
            : <Link prefetch={false} key={a.key} className={`btn ${a.primary ? 'btn--primary' : 'now__btn'}`} href={a.href} data-testid={a.testId}>{a.label}</Link>)}
          {extra}
        </div>
      )}
      {children}
    </section>
  );
}
