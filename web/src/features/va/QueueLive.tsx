'use client';
import { useEffect } from 'react';
import { useRouter } from 'next/navigation';

// New tasks appear without a reload: the queue is read again every 30 seconds while the tab is visible,
// and the open count shows in the browser tab's title.
export function QueueLive({ open }: { open: number }) {
  const router = useRouter();
  useEffect(() => {
    const base = document.title.replace(/^\(\d+\)\s*/, '');
    document.title = open ? `(${open}) ${base}` : base;
    const t = setInterval(() => { if (document.visibilityState === 'visible') router.refresh(); }, 30_000);
    return () => clearInterval(t);
  }, [open, router]);
  return null;
}
