'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useState, type ReactNode } from 'react';

export function NavLink({ href, className, children }: { href: string; className?: string; children: ReactNode }) {
  const path = usePathname();
  const current = path === href || (href !== '/' && path.startsWith(href + '/'));
  return <Link prefetch={false} className={className} href={href} aria-current={current ? 'page' : undefined}>{children}</Link>;
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
