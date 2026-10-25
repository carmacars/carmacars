import type { ReactNode } from 'react';

/**
 * The top of a portal home: a dark band with the kicker, the greeting or title, one line, a row of figures, actions,
 * and (from 64rem) media on the right, such as the owner's cars or the investor's growth chart.
 */
export function PortalHero({ kicker, title, lead, stats, actions, media, testId, titleId }: {
  kicker?: ReactNode; title: ReactNode; lead?: ReactNode; stats?: ReactNode; actions?: ReactNode; media?: ReactNode; testId?: string; titleId?: string;
}) {
  return (
    <section className={`pu-hero${media ? ' pu-hero--split' : ''}`} data-testid={testId} aria-labelledby={titleId}>
      <div className="pu-hero__head">
        {kicker && <p className="pu-hero__kicker">{kicker}</p>}
        <h1 className="pu-hero__title" id={titleId}>{title}</h1>
        {lead && <p className="pu-hero__lead">{lead}</p>}
      </div>
      {stats && <div className="pu-hero__stats">{stats}</div>}
      {actions && <div className="pu-hero__actions">{actions}</div>}
      {media && <div className="pu-hero__media">{media}</div>}
    </section>
  );
}
