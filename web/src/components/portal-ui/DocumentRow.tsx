import Link from 'next/link';
import type { ReactNode } from 'react';

/**
 * A statement, invoice or agreement as one elegant row: a file badge, the title (the whole row opens it), what it is and
 * when, and on the right its amount and status. `external` uses a plain link (a PDF route), not client navigation.
 */
export function DocumentRow({ href, title, meta, badge = 'PDF', amount, status, action, accent = false, external = false, testId, linkTestId, dataAttrs }: {
  href: string; title: ReactNode; meta?: ReactNode; badge?: string; amount?: ReactNode; status?: ReactNode; action?: ReactNode; accent?: boolean; external?: boolean; testId?: string;
  /** a test id on the link itself (the renter's documents: tests read its href) */ linkTestId?: string;
  dataAttrs?: Record<string, string>;
}) {
  return (
    <li className={`pu-doc${accent ? ' pu-doc--accent' : ''}`} data-testid={testId} {...dataAttrs}>
      <span className="pu-doc__icon" aria-hidden="true">{badge}</span>
      <span className="pu-doc__text">
        {external ? <a className="pu-doc__title" href={href} data-testid={linkTestId}>{title}</a> : <Link prefetch={false} className="pu-doc__title" href={href} data-testid={linkTestId}>{title}</Link>}
        {meta && <span className="pu-doc__meta">{meta}</span>}
      </span>
      {(amount !== undefined || status || action) && <span className="pu-doc__side">{amount !== undefined && <span className="pu-doc__amount">{amount}</span>}{status}{action}</span>}
    </li>
  );
}

/** `plain`: no card of its own, for a list inside a panel. */
export function DocumentList({ children, testId, label, plain = false }: { children: ReactNode; testId?: string; label?: string; plain?: boolean }) {
  return <ul className={`pu-docs${plain ? ' pu-docs--plain' : ''}`} data-testid={testId} aria-label={label}>{children}</ul>;
}
