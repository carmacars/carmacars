'use client';
import { useEffect } from 'react';
import { afterReset, RESET } from './model';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';

// r32: the last filters of a list are remembered for this person on this device (a convenience: nothing else depends
// on it). Opening the list with no filter brings them back; Clear (?clear=1) forgets them.
export function RememberFilters({ id, names }: { id: string; names: string[] }) {
  const router = useRouter();
  const path = usePathname();
  const sp = useSearchParams();
  useEffect(() => {
    const key = `lf:${id}`;
    try {
      if (sp.get('clear') === '1') {
        localStorage.removeItem(key);
        const q = new URLSearchParams(sp.toString());
        q.delete('clear'); for (const n of names) q.delete(n);
        router.replace(q.toString() ? `${path}?${q}` : path, { scroll: false });
        return;
      }
      const reset = sp.get(RESET);
      if (reset) { // the default chip was chosen: forget the remembered choice of that filter, then show the list without the marker
        const left = afterReset(JSON.parse(localStorage.getItem(key) ?? 'null') as Record<string, string> | null, reset);
        if (left) localStorage.setItem(key, JSON.stringify(left)); else localStorage.removeItem(key);
        const q = new URLSearchParams(sp.toString());
        q.delete(RESET);
        router.replace(q.toString() ? `${path}?${q}` : path, { scroll: false });
        return;
      }
      const mine = names.filter((n) => sp.get(n));
      if (mine.length) {
        localStorage.setItem(key, JSON.stringify(Object.fromEntries(mine.map((n) => [n, sp.get(n)]))));
        return;
      }
      const saved = JSON.parse(localStorage.getItem(key) ?? 'null') as Record<string, string> | null;
      if (saved && Object.keys(saved).length) {
        const q = new URLSearchParams(sp.toString());
        for (const [k, v] of Object.entries(saved)) if (names.includes(k) && v) q.set(k, v);
        router.replace(`${path}?${q}`, { scroll: false });
      }
    } catch { /* private window or blocked storage: the list works without it */ }
  }, [id, names, path, router, sp]);
  return null;
}
