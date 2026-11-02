import 'server-only';
import '@/styles/alerts.css';
import Link from '@/components/Link';
import { alertUnread } from '@/server/alerts';

// The bell of the Admin and staff portals (migration 0466): the person's unread alerts; it opens the Alerts feed.
export async function AlertsBell({ userId, href }: { userId: string; href: string }) {
  const n = await alertUnread(userId);
  const label = n > 0 ? `Alerts, ${n} unread` : 'Alerts';
  return (
    <Link prefetch={false} href={href} className="al-bell" aria-label={label} title={label} data-testid="alerts-bell">
      <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
        <path d="M6 16.5V11a6 6 0 1 1 12 0v5.5l1.5 2h-15z" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round" />
        <path d="M10 20.5a2 2 0 0 0 4 0" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
      </svg>
      {n > 0 && <span className="al-bell__n" data-testid="alerts-bell-count">{n > 99 ? '99+' : n}</span>}
    </Link>
  );
}
