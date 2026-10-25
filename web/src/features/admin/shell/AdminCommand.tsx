'use client';
import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import type { NavGroup } from '../GroupNav';
import { rank, type Item } from './jump';

// Jump to any admin page by typing a few letters (admin portal design, October 25, 2026): Ctrl+K (Cmd+K on a Mac) or
// the "Jump to" button opens it; arrows choose, Enter goes, Esc closes. The first line searches the records (bookings,
// cars, owners, renters) for what was typed, the same as the search box. The pages are the menu's and every settings
// page (the layout passes them); each still checks who may open it.

export function AdminCommand({ groups }: { groups: NavGroup[] }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const idp = useId().replace(/:/g, '');
  const [q, setQ] = useState('');
  const [at, setAt] = useState(0);
  const items = useMemo<Item[]>(() => {
    const seen = new Set<string>();
    return groups.flatMap((g) => {
      let section = '';
      return g.links.flatMap((l) => {
        if (l.section) section = l.section;
        if (seen.has(l.href)) return [];
        seen.add(l.href);
        return [{ href: l.href, label: l.label, where: section ? `${g.label}, ${section}` : g.label, key: l.key }];
      });
    });
  }, [groups]);
  const found = useMemo(() => rank(items, q).slice(0, 12), [items, q]);
  const search: Item[] = q.trim() ? [{ href: `/admin/search?q=${encodeURIComponent(q.trim())}`, label: `Search records for "${q.trim()}"`, where: 'Bookings, cars, owners, partners and renters' }] : [];
  const options: Item[] = [...search, ...found];

  const open = () => { setQ(''); setAt(0); dlg.current?.showModal(); requestAnimationFrame(() => input.current?.focus()); };
  const go = (href: string) => { dlg.current?.close(); router.push(href); };

  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        if (dlg.current?.open) dlg.current.close(); else open();
      }
    };
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  });

  const onKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setAt((a) => Math.min(options.length - 1, a + 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setAt((a) => Math.max(0, a - 1)); }
    else if (e.key === 'Enter') { e.preventDefault(); const o = options[at]; if (o) go(o.href); }
  };
  const list = `${idp}-list`;
  return (
    <>
      <button type="button" className="ad-jump" onClick={open} aria-haspopup="dialog" aria-keyshortcuts="Control+K Meta+K" data-testid="admin-jump">
        <svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M8.5 3a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11zM12.5 12.5 17 17" /></svg>
        <span>Jump to a page</span>
        <kbd className="ad-kbd" aria-hidden="true">Ctrl K</kbd>
      </button>
      <dialog ref={dlg} className="ad-cmd" aria-labelledby={`${idp}-t`} data-testid="admin-jump-dialog" onClick={(e) => { if (e.target === dlg.current) dlg.current?.close(); }}>
        <h2 className="vh" id={`${idp}-t`}>Jump to a page</h2>
        <div className="ad-cmd__field">
          <svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M8.5 3a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11zM12.5 12.5 17 17" /></svg>
          <label className="vh" htmlFor={`${idp}-q`}>Page name, or a booking, plate or name to search for</label>
          <input ref={input} id={`${idp}-q`} className="ad-cmd__input" type="text" role="combobox" aria-expanded="true" aria-controls={list} aria-autocomplete="list"
            aria-activedescendant={options[at] ? `${idp}-o${at}` : undefined} autoComplete="off" spellCheck={false} placeholder="Type a page, a booking or a name"
            value={q} onChange={(e) => { setQ(e.target.value); setAt(0); }} onKeyDown={onKey} data-testid="admin-jump-input" />
          <kbd className="ad-kbd" aria-hidden="true">Esc</kbd>
        </div>
        <ul className="ad-cmd__list" id={list} role="listbox" aria-label="Pages">
          {options.map((o, i) => (
            <li key={o.href} id={`${idp}-o${i}`} role="option" aria-selected={i === at} className={`ad-cmd__opt${i === at ? ' is-on' : ''}`}
              onMouseEnter={() => setAt(i)} onClick={() => go(o.href)}>
              <span className="ad-cmd__label">{o.label}</span>
              <span className="ad-cmd__where">{o.where}</span>
              {o.key ? <kbd className="ad-kbd" aria-hidden="true">g {o.key}</kbd> : null}
            </li>
          ))}
        </ul>
        <p className="ad-cmd__foot" aria-hidden="true"><span><kbd className="ad-kbd">↑</kbd><kbd className="ad-kbd">↓</kbd> choose</span><span><kbd className="ad-kbd">Enter</kbd> open</span><span><kbd className="ad-kbd">/</kbd> search box</span></p>
      </dialog>
    </>
  );
}
