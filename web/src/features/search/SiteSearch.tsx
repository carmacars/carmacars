'use client';
import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { GROUP_LABEL, rankItems, type Group, type Item } from './index-items';

// The one search box of the site and every portal (release 28, B4), in the header. "/" or Ctrl+K (Cmd+K on a Mac)
// opens it, except where a page has its own: an Admin page keeps Ctrl+K for "Jump to a page", and "/" goes to a page's
// own search field where it has one. On a phone it fills the screen.
//   public   pages, the portals' doors, cars, places and guides: one small list (/api/search/index) searched here
//   signed in  also the person's own records (/api/search/mine), as each role may see them (migration 0561)
// Arrows choose, Enter opens, Esc closes.

interface RecordGroup { key: string; label: string; rows: Array<{ title: string; sub: string; href: string }> }
type Option = { key: string; label: string; sub?: string; href: string; group: string };

let indexLoad: Promise<Item[]> | null = null;
function loadIndex(): Promise<Item[]> {
  indexLoad ??= fetch('/api/search/index', { credentials: 'omit' }).then((r) => (r.ok ? r.json() : { items: [] }))
    .then((j: { items?: Item[] }) => (Array.isArray(j.items) ? j.items : []))
    .catch(() => { indexLoad = null; return [] as Item[]; });
  return indexLoad;
}
const ORDER: Group[] = ['portals', 'pages', 'cars', 'places', 'guides', 'help'];

export function SiteSearch() {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const idp = useId().replace(/[^\w-]/g, '');
  const [items, setItems] = useState<Item[]>([]);
  const [q, setQ] = useState('');
  const [at, setAt] = useState(0);
  const [records, setRecords] = useState<{ q: string; groups: RecordGroup[]; message?: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const signedOut = useRef(false);

  const open = () => {
    setQ(''); setAt(0); setRecords(null);
    if (!dlg.current?.open) dlg.current?.showModal();
    requestAnimationFrame(() => input.current?.focus());
    void loadIndex().then(setItems);
  };
  const close = () => dlg.current?.close();

  // the shortcuts
  useEffect(() => {
    const typing = (t: EventTarget | null) => t instanceof HTMLElement && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
    const on = (e: KeyboardEvent) => {
      if (dlg.current?.open) return;
      const k = (e.key ?? '').toLowerCase(); // autofill fires keydown with no key
      if ((e.metaKey || e.ctrlKey) && !e.altKey && k === 'k') {
        if (document.querySelector('[data-testid="admin-jump"]')) return;   // Admin's own "Jump to a page"
        e.preventDefault(); open(); return;
      }
      if (e.key === '/' && !e.metaKey && !e.ctrlKey && !e.altKey && !typing(e.target)) {
        if (document.querySelector('[data-shortcut="/"]')) return;          // the page's own search field
        e.preventDefault(); open();
      }
    };
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  });

  // the person's own records, a moment after typing stops
  useEffect(() => {
    const term = q.trim();
    if (term.length < 2 || signedOut.current) return;
    let live = true;
    const t = window.setTimeout(() => {
      setBusy(true);
      fetch(`/api/search/mine?q=${encodeURIComponent(term)}`, { credentials: 'same-origin', cache: 'no-store' })
        .then((r) => r.json())
        .then((j: { q: string; groups?: RecordGroup[]; signedIn?: boolean; message?: string }) => {
          if (!live) return;
          if (j.signedIn === false) { signedOut.current = true; setRecords(null); return; }
          setRecords({ q: term, groups: Array.isArray(j.groups) ? j.groups : [], message: j.message });
        })
        .catch(() => undefined)
        .finally(() => { if (live) setBusy(false); });
    }, 220);
    return () => { live = false; window.clearTimeout(t); };
  }, [q]);

  const options = useMemo<Option[]>(() => {
    const term = q.trim();
    if (!term) return [];
    const out: Option[] = [];
    if (records && records.q === term) {
      for (const g of records.groups) for (const r of g.rows.slice(0, 6)) out.push({ key: `r-${g.key}-${r.href}`, label: r.title, sub: r.sub, href: r.href, group: g.label });
    }
    const found = rankItems(items, term, 24);
    for (const g of ORDER) for (const it of found.filter((x) => x.g === g).slice(0, 6)) out.push({ key: `i-${it.h}-${it.t}`, label: it.t, sub: it.s, href: it.h, group: GROUP_LABEL[g] });
    return out;
  }, [q, items, records]);

  const go = (href: string) => { close(); router.push(href); };
  const onKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setAt((a) => Math.min(options.length - 1, a + 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setAt((a) => Math.max(0, a - 1)); }
    else if (e.key === 'Enter') { e.preventDefault(); const o = options[at]; if (o) go(o.href); }
  };
  useEffect(() => { document.getElementById(`${idp}-o${at}`)?.scrollIntoView({ block: 'nearest' }); }, [at, idp]);

  const list = `${idp}-list`;
  let lastGroup = '';
  return (
    <>
      <button type="button" className="site-search-btn" onClick={open} aria-label="Search" aria-haspopup="dialog" aria-keyshortcuts="/ Control+K Meta+K" data-testid="site-search">
        <svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round"><path d="M8.5 3a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11zM12.5 12.5 17 17" /></svg>
        <span className="site-search-btn__label">Search</span>
        <kbd className="site-search-btn__kbd" aria-hidden="true">/</kbd>
      </button>
      <dialog ref={dlg} className="ssr" aria-labelledby={`${idp}-t`} data-testid="site-search-dialog" onClick={(e) => { if (e.target === dlg.current) close(); }}>
        <div className="ssr__panel">
          <h2 className="vh" id={`${idp}-t`}>Search CarmaCars</h2>
          <div className="ssr__field">
            <svg viewBox="0 0 20 20" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round"><path d="M8.5 3a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11zM12.5 12.5 17 17" /></svg>
            <label className="vh" htmlFor={`${idp}-q`}>Search pages, cars, places, guides and your records</label>
            <input ref={input} id={`${idp}-q`} className="ssr__input" type="search" role="combobox" aria-expanded={options.length > 0} aria-controls={list} aria-autocomplete="list"
              aria-activedescendant={options[at] ? `${idp}-o${at}` : undefined} autoComplete="off" spellCheck={false} enterKeyHint="go"
              placeholder="A car, a page, a booking number" value={q} onChange={(e) => { setQ(e.target.value); setAt(0); }} onKeyDown={onKey} data-testid="site-search-input" />
            <button type="button" className="ssr__close" onClick={close} aria-label="Close the search">Esc</button>
          </div>
          <ul className="ssr__list" id={list} role="listbox" aria-label="Results" data-testid="site-search-results">
            {options.map((o, i) => {
              const head = o.group !== lastGroup ? o.group : null;
              lastGroup = o.group;
              return (
                <li key={o.key} id={`${idp}-o${i}`} role="option" aria-selected={i === at} className={`ssr__opt${i === at ? ' is-on' : ''}${head ? ' ssr__opt--first' : ''}`}
                  data-group={head ?? undefined} onMouseEnter={() => setAt(i)} onClick={() => go(o.href)}>
                  <span className="ssr__label">{o.label}</span>
                  {o.sub && <span className="ssr__sub">{o.sub}</span>}
                </li>);
            })}
          </ul>
          <p className="ssr__foot" role="status" aria-live="polite">
            {!q.trim() ? 'Pages, cars, places and guides. Signed in, your bookings and records too.'
              : busy && !options.length ? 'Searching'
              : records?.message ?? (!options.length ? `Nothing matches "${q.trim()}". Try fewer letters, a car's make, or a booking number.` : `${options.length} found`)}
          </p>
        </div>
      </dialog>
    </>
  );
}
