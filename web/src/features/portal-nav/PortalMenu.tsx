'use client';
import Link from '@/components/Link';
import { usePathname } from 'next/navigation';
import { currentLink, menuFor, type MenuIcon, type MenuLink } from './tabs';

// The customer portals' menu (r27 portals): at most five links, each with its icon. On a phone one row of equal cells
// (icon above the word, 52px tall, never wrapping); from 48rem a pill track like the admin tab row, the current link
// black. The links come from each portal's menu (features/portal/menu.ts, owner/menu.ts, investor/menu.ts).
const ICON: Record<MenuIcon, React.ReactNode> = {
  home: <><path d="M4 11.2 12 4.5l8 6.7" /><path d="M6.5 9.5V19.5h11V9.5" /><path d="M10 19.5v-5h4v5" /></>,
  car: <><path d="M4 15.5V12l1.6-4.3A2 2 0 0 1 7.5 6.4h9a2 2 0 0 1 1.9 1.3L20 12v3.5" /><path d="M4 15.5h16v2H4z" /><path d="M4.5 12h15" /><circle cx="7.5" cy="14" r=".6" /><circle cx="16.5" cy="14" r=".6" /></>,
  doc: <><path d="M7 3.5h7l4.5 4.5v11a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5z" /><path d="M14 3.5V8h4.5M8.5 12.5h7M8.5 16h5" /></>,
  star: <path d="M12 4l2.4 5 5.4.7-4 3.7 1 5.4L12 16.2 7.2 18.8l1-5.4-4-3.7 5.4-.7z" />,
  user: <><circle cx="12" cy="8.5" r="3.7" /><path d="M4.8 19.5a7.2 7.2 0 0 1 14.4 0" /></>,
  card: <><rect x="3" y="6" width="18" height="12.5" rx="2.2" /><path d="M3 10h18M6.5 15h4" /></>,
  chart: <><path d="M4 19.5h16" /><path d="M7 16v-4.5M11 16V7.5M15 16v-6M19 16V5" /></>,
  play: <><rect x="3.5" y="5" width="17" height="14" rx="2.5" /><path d="M10 9.2v5.6l4.6-2.8z" /></>
};

export function PortalMenu({ menu, label, flags = {}, unread = 0, testId }: { menu: MenuLink[]; label: string; flags?: Record<string, boolean>; unread?: number; testId?: string }) {
  const path = usePathname() ?? '';
  const links = menuFor(menu, flags);
  const current = currentLink(links, path);
  return (
    <nav className="pm" aria-label={label} data-testid={testId} style={{ ['--pm-n' as string]: links.length }}>
      {links.map((l) => (
        <Link prefetch={false} key={l.href} href={l.href} aria-current={current === l ? 'page' : undefined} data-testid={l.when === 'deck' ? 'nav-deck' : undefined}>
          <svg className="pm__icon" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">{ICON[l.icon]}</svg>
          <span className="pm__label">{l.label}</span>
          {l.count === 'unread' && unread > 0 && <span className="pt__count pm__count" aria-label={`${unread} unread`}>{unread}</span>}
        </Link>
      ))}
    </nav>
  );
}
