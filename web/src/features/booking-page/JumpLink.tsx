'use client';
import { useEffect } from 'react';
import Link from '@/components/Link';

// r38 (owner, Nov 11): "What's left" on the booking page: a link to where a thing is done. On the same tab it scrolls there
// smoothly and the section is lit for a moment; on another tab it opens that tab and the page lands on the section.
const HILITE = 'is-jump-target';
function light(id: string): boolean {
  const el = typeof document !== 'undefined' ? document.getElementById(id) : null;
  if (!el) return false;
  const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  el.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' });
  el.classList.add(HILITE);
  window.setTimeout(() => el.classList.remove(HILITE), 1600);
  return true;
}

export function JumpLink({ href, testId, children }: { href: string; testId?: string; children: React.ReactNode }) {
  // the page opened on another tab with the anchor: light the section once it is there
  useEffect(() => { const h = window.location.hash.slice(1); if (h && h === href.split('#')[1]) light(h); }, [href]);
  return (
    <Link prefetch={false} className="link" href={href} data-testid={testId} onClick={(e) => {
      const [path, id] = href.split('#');
      const here = typeof window !== 'undefined' && `${window.location.pathname}${window.location.search}` === path;
      if (here && id && light(id)) { e.preventDefault(); history.replaceState(null, '', `#${id}`); }
    }}>{children}</Link>
  );
}
