'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useState, type ReactNode } from 'react';

export function NavLink({ href, className, children }: { href: string; className?: string; children: ReactNode }) {
  const path = usePathname();
  const current = path === href || (href !== '/' && path.startsWith(href + '/'));
  return <Link prefetch={false} className={className} href={href} aria-current={current ? 'page' : undefined}>{children}</Link>;
}

// "Sign in" on the public pages; inside a portal (signed in by then) the same place goes back to that portal's home.
const PORTAL = /^\/(account|owner|admin|va|field|staff|investor)(\/|$)/;
/** The portal a path is in (account, owner, admin, va, field, investor), or null on the public site. */
export function portalOf(path: string | null): string | null { return PORTAL.exec(path ?? '')?.[1] ?? null; }

// Inside a portal (the owner's feedback of October 23, 2026: the portals felt cluttered) the public site's menu and its
// long footer step aside: the portal's own tabs are the navigation there. The public pages stay one tap away (the
// wordmark, the Menu on a phone, the short footer). `keep` names the portals that still show the children.
export function PublicOnly({ children, keep = [] }: { children: ReactNode; keep?: string[] }) {
  const portal = portalOf(usePathname());
  return portal && !keep.includes(portal) ? null : <>{children}</>;
}
export function PortalSwitchFooter({ full, compact }: { full: ReactNode; compact: ReactNode }) {
  return portalOf(usePathname()) ? <>{compact}</> : <>{full}</>;
}
export function AccountLink({ className }: { className?: string }) {
  const portal = PORTAL.exec(usePathname())?.[1];
  return <Link prefetch={false} className={className} href={portal ? `/${portal}` : '/sign-in'}>{portal ? 'Your portal' : 'Sign in'}</Link>;
}

// The phone menu: a button with aria-expanded; the panel is inert while closed; Escape closes.
export function MenuButton() {
  const path = usePathname();
  const [openAt, setOpenAt] = useState<string | null>(null);
  const open = openAt === path;
  const setOpen = (v: boolean) => setOpenAt(v ? path : null);
  useEffect(() => {
    const panel = document.getElementById('menu');
    if (!panel) return;
    panel.classList.toggle('is-open', open);
    panel.inert = !open;
    document.body.style.overflow = open ? 'hidden' : '';
    if (open) panel.querySelector('a')?.focus();
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    const onClick = (e: MouseEvent) => { if ((e.target as HTMLElement).closest('a')) setOpen(false); };
    const mq = window.matchMedia('(min-width: 64rem)');
    const onMq = () => setOpen(false);
    document.addEventListener('keydown', onKey); panel.addEventListener('click', onClick); mq.addEventListener('change', onMq);
    return () => { document.removeEventListener('keydown', onKey); panel.removeEventListener('click', onClick); mq.removeEventListener('change', onMq); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);
  return (
    <button type="button" className="menu-btn" aria-expanded={open} aria-controls="menu" onClick={() => setOpen(!open)}>
      <span>{open ? 'Close' : 'Menu'}</span><i aria-hidden="true"></i>
    </button>
  );
}
