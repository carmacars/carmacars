'use client';
import { useEffect, useState } from 'react';
import Link from '@/components/Link';
import './still-needed.css';

// r40: the r38 phone bar (.sn__next) with the Do this next button, shown only once the card is off the screen, so it
// never covers the card; clear of the chat button on the right.
export function StickyNext({ watch, href, label, testId }: { watch: string; href: string; label: string; testId?: string }) {
  const [away, setAway] = useState(false);
  useEffect(() => {
    const el = document.querySelector(`[data-testid="${watch}"]`);
    if (!el || typeof IntersectionObserver === 'undefined') return;
    const io = new IntersectionObserver(([e]) => setAway(!!e && !e.isIntersecting && e.boundingClientRect.top < 0), { threshold: 0 });
    io.observe(el);
    return () => io.disconnect();
  }, [watch]);
  if (!away) return null;
  return (
    <div className="sn__next" data-testid={testId} style={{ paddingRight: 'calc(var(--s-3) + 72px)' }}>
      <Link prefetch={false} className="btn btn--primary btn--sm" href={href}>Next: {label}</Link>
    </div>
  );
}
