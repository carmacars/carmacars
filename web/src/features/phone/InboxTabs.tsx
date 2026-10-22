import Link from 'next/link';

// Live chat and Texts and calls share one page (migration 0085): two tabs.
export function InboxTabs({ base, view, unread }: { base: string; view: 'chat' | 'phone'; unread?: number }) {
  return (
    <nav className="ad-chip-row ph-tabs" aria-label="Inbox">
      <Link prefetch={false} className={`btn btn--sm ${view === 'chat' ? 'btn--primary' : 'btn--quiet'}`} aria-current={view === 'chat' ? 'page' : undefined} href={base}>Live chat</Link>
      <Link prefetch={false} className={`btn btn--sm ${view === 'phone' ? 'btn--primary' : 'btn--quiet'}`} aria-current={view === 'phone' ? 'page' : undefined} href={`${base}?view=phone`} data-testid="tab-phone">
        Texts and calls{unread ? ` (${unread})` : ''}</Link>
    </nav>
  );
}
