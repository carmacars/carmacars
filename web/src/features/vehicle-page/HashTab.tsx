'use client';
import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { tabForHash } from './tabs';

// r31: the vehicle page has tabs for staff too. Old links point at a part of the page by its hash (#maintenance, from task
// links and bookmarks); a server cannot read a hash, so the page moves to the tab that holds it, keeping the rest of the
// address (?record=1 still opens the record pop-up).
export function HashTab({ tabs, current }: { tabs: string[]; current: string }) {
  const router = useRouter();
  useEffect(() => {
    const t = tabForHash(window.location.hash, tabs);
    if (!t || t === current) return;
    const u = new URL(window.location.href);
    u.searchParams.set('tab', t);
    u.hash = '';
    router.replace(`${u.pathname}${u.search}`, { scroll: false });
  }, [tabs, current, router]);
  return null;
}
