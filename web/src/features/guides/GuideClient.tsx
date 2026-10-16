'use client';
import { useEffect, useId, useRef, useState } from 'react';
import { usePathname } from 'next/navigation';
import { dismissGuideBanner } from '@/server/actions/guides';
import { SEEN_COOKIE } from './constants';

// The guide page's browser parts: search within the guide, "Print or save as PDF", and the per-device note that the
// banner was seen (the record itself is in the database: guide_reads).

export function markSeen(portal: string) {
  try {
    const now = (document.cookie.split('; ').find((c) => c.startsWith(SEEN_COOKIE + '='))?.split('=')[1] ?? '').split('.').filter(Boolean);
    if (!now.includes(portal)) now.push(portal);
    document.cookie = `${SEEN_COOKIE}=${now.join('.')}; path=/; max-age=${60 * 60 * 24 * 365}; samesite=lax`;
  } catch { /* cookies blocked: the database still knows */ }
}

/** Notes on this device that the person has the guide (opening it ends the first-visit banner). */
export function GuideSeen({ portal }: { portal: string }) {
  useEffect(() => {
    markSeen(portal);
    // the contents: collapsed on a phone (the guide starts at once), a sidebar on a wide screen, always printed
    const toc = document.querySelector<HTMLDetailsElement>('details.gd-toc');
    if (!toc) return;
    const wide = window.matchMedia('(min-width: 72rem)');
    const fit = () => { if (wide.matches) toc.open = true; };
    const print = () => { toc.open = true; };
    fit();
    wide.addEventListener('change', fit);
    window.addEventListener('beforeprint', print);
    return () => { wide.removeEventListener('change', fit); window.removeEventListener('beforeprint', print); };
  }, [portal]);
  return null;
}

const norm = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '');

export function GuideTools({ mode }: { mode: 'print' | 'search' }) {
  const id = useId();
  const [q, setQ] = useState('');
  const [note, setNote] = useState('');
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (mode !== 'search') return;
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => {
      const words = norm(q).split(/\s+/).filter((w) => w.length > 1);
      const sections = [...document.querySelectorAll<HTMLElement>('[data-gd-section]')];
      let hits = 0;
      for (const sec of sections) {
        const tasks = [...sec.querySelectorAll<HTMLElement>('[data-gd-task]')];
        const title = norm(sec.querySelector('.gd-sec-title')?.textContent ?? '');
        let shown = 0;
        for (const t of tasks) {
          const ok = !words.length || words.every((w) => norm(t.textContent ?? '').includes(w) || title.includes(w));
          t.classList.toggle('gd-hidden', !ok);
          if (ok) shown++;
        }
        const own = !words.length || (tasks.length === 0 && words.every((w) => norm(sec.textContent ?? '').includes(w)));
        sec.classList.toggle('gd-hidden', !(own || shown > 0));
        if (words.length) hits += tasks.length ? shown : own ? 1 : 0;
      }
      setNote(!words.length ? '' : hits ? `${hits} ${hits === 1 ? 'part matches' : 'parts match'} "${q.trim()}".` : `Nothing in this guide matches "${q.trim()}".`);
    }, 150);
    return () => { if (timer.current) clearTimeout(timer.current); };
  }, [q, mode]);

  if (mode === 'print') {
    return <button type="button" className="btn btn--ghost btn--sm" onClick={() => window.print()} data-testid="guide-print">Print or save as PDF</button>;
  }
  return (
    <div className="gd-noprint">
      <form className="gd-search" role="search" onSubmit={(e) => e.preventDefault()}>
        <label className="vh" htmlFor={`${id}-q`}>Search this guide</label>
        <input className="input" id={`${id}-q`} type="search" placeholder="Search this guide" value={q} onChange={(e) => setQ(e.target.value)} data-testid="guide-search" autoComplete="off" />
        {q && <button type="button" className="btn btn--quiet btn--sm" onClick={() => setQ('')}>Clear</button>}
      </form>
      <p className="gd-searchnote" role="status" aria-live="polite" data-testid="guide-search-note">{note}</p>
    </div>
  );
}

/** The first-visit banner's buttons: open the guide, or dismiss it (recorded for the person, and on this device). */
export function GuideBannerClient({ portal, href, name }: { portal: string; href: string; name: string }) {
  const [gone, setGone] = useState(false);
  const [busy, setBusy] = useState(false);
  const path = usePathname();
  // on the guide itself the banner has done its job
  if (gone || path === href) return null;
  return (
    <div className="gd-banner gd-noprint" role="region" aria-label="Guide" data-testid="guide-banner">
      <p>New here? Read the {name} guide.</p>
      <a className="btn btn--primary btn--sm" href={href} onClick={() => markSeen(portal)}>Open the guide</a>
      <button type="button" className="btn btn--quiet btn--sm" disabled={busy} data-testid="guide-banner-dismiss"
        onClick={async () => { setBusy(true); markSeen(portal); setGone(true); await dismissGuideBanner(portal).catch(() => undefined); }}>Not now</button>
    </div>
  );
}
