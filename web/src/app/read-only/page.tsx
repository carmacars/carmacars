import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'Read only', path: '/read-only', noindex: true, description: 'Nothing can be changed while viewing as another person.' });

// Where a button lands when an Admin presses it while viewing as someone (src/lib/security/view-as-guard.ts).
export default function ReadOnly() {
  return (
    <div className="container" style={{ maxWidth: '36rem', paddingBlock: 'var(--s-7)' }}>
      <div className="stack-lg pt-empty" data-testid="read-only">
        <h1 className="d3">Read only</h1>
        <p>You are viewing CarmaCars as another person, so nothing was changed.</p>
        <p className="muted">To act for them, use the Admin portal, or ask them to do it from their own account.</p>
        <div className="row" style={{ justifyContent: 'center', flexWrap: 'wrap', gap: 'var(--s-3)' }}>
          <Link prefetch={false} className="btn btn--ghost" href="/admin/portals">Admin &gt; Portals</Link>
          <form method="post" action="/api/view-as/exit"><button className="btn btn--primary" type="submit">Exit view</button></form>
        </div>
      </div>
    </div>
  );
}
