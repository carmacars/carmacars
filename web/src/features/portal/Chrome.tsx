import Link from 'next/link';
import type { ReactNode } from 'react';

// The portals' shared pieces since the cleanup of October 23, 2026 (the owner's feedback: "a lot of confusion and
// clutter in the portals"): one page header (title, one line on what the page is for, one primary action), one
// "needs your attention" list (each item with one clear action) and one disclosure for the details most visits skip.

/** A page's header: the title, what the page is for in one line, and its one primary action. */
export function PageHeader({ title, purpose, kicker, action, testId }: { title: ReactNode; purpose?: ReactNode; kicker?: ReactNode; action?: ReactNode; testId?: string }) {
  return (
    <header className="ph" data-testid={testId}>
      <div className="ph__text">{kicker && <p className="pt-kicker">{kicker}</p>}<h1 className="d2">{title}</h1>{purpose && <p className="ph__purpose">{purpose}</p>}</div>
      {action && <div className="ph__action">{action}</div>}
    </header>
  );
}

export interface AttentionItem { key: string; title: ReactNode; note?: ReactNode; href: string; cta: string; testId?: string }
/** What needs the person now: one line each, one button each. Nothing to show: nothing rendered. */
export function Attention({ items, title = 'Needs your attention', testId = 'attention' }: { items: AttentionItem[]; title?: string; testId?: string }) {
  if (!items.length) return null;
  return (
    <section className="stack" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <h2 className="pt-section-title" id={`${testId}-h`}>{title}</h2>
      <ul className="attn">{items.map((i) => (
        <li key={i.key} data-testid={i.testId}>
          <span className="attn__text"><b>{i.title}</b>{i.note && <span className="small muted">{i.note}</span>}</span>
          <Link prefetch={false} className="btn btn--ghost btn--sm" href={i.href}>{i.cta}</Link>
        </li>))}
      </ul>
    </section>
  );
}

/** Details most visits do not need, one tap away. */
export function More({ summary, children, open = false, testId }: { summary: ReactNode; children: ReactNode; open?: boolean; testId?: string }) {
  return <details className="pt-more" open={open} data-testid={testId}><summary>{summary}</summary><div className="pt-more__body">{children}</div></details>;
}
