import type { ReactNode } from 'react';
import { PortalIcon, type PortalIconName } from './icons';

// Small portal-ui pieces: a panel with a title row, a smooth disclosure, an empty state and the loading shapes.
const cx = (...c: Array<string | false | null | undefined>) => c.filter(Boolean).join(' ');

/** A white card with a title row (and an optional link or action at its right). */
export function PortalCard({ id, title, action, children, tone, testId, className }: { id: string; title: ReactNode; action?: ReactNode; children: ReactNode; tone?: 'next'; testId?: string; className?: string }) {
  return (
    <section className={cx('pu-panel', tone === 'next' && 'pu-panel--next', className)} id={id} aria-labelledby={`${id}-h`} data-testid={testId}>
      <div className="pu-panel__head"><h2 className="pu-title" id={`${id}-h`}>{title}</h2>{action}</div>
      {children}
    </section>
  );
}

/** Details most visits skip, opened smoothly where the browser can animate it. */
export function Disclosure({ summary, children, open = false, testId }: { summary: ReactNode; children: ReactNode; open?: boolean; testId?: string }) {
  return <details className="pu-disclosure" open={open} data-testid={testId}><summary>{summary}<PortalIcon name="arrow" size={16} className="pu-disclosure__chev" /></summary><div className="pu-disclosure__body">{children}</div></details>;
}

/** Nothing here yet: an icon, a line, what to do, and one button. */
export function EmptyState({ icon = 'car', title, children, action, testId }: { icon?: PortalIconName; title: ReactNode; children?: ReactNode; action?: ReactNode; testId?: string }) {
  return (
    <div className="pu-empty" data-testid={testId}>
      <span className="pu-empty__icon"><PortalIcon name={icon} size={28} /></span>
      <p className="pu-empty__title">{title}</p>
      {children && <div className="pu-empty__text">{children}</div>}
      {action}
    </div>
  );
}

/** Loading placeholders in the shape of the hero and the cards (screen readers hear "Loading"). */
export function HeroSkeleton() {
  return (
    <div className="pu-sk" role="status">
      <span className="vh">Loading</span>
      <div className="pu-sk__hero skeleton" aria-hidden="true" />
      <div className="pu-stats" aria-hidden="true">{[0, 1, 2, 3].map((i) => <div key={i} className="pu-sk__stat skeleton" />)}</div>
      <div className="pu-sk__card skeleton" aria-hidden="true" />
    </div>
  );
}
