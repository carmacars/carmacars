'use client';
import Link from '@/components/Link';
import { useState } from 'react';
import { cardMatches, type SettingsCard } from './groups';

// The Settings page's sections (r27): an anchor row, a search box that filters the cards as you type, and each section's
// cards. Without JavaScript every card shows.
export function SettingsIndex({ sections }: { sections: Array<{ id: string; title: string; about: string; cards: SettingsCard[] }> }) {
  const [q, setQ] = useState('');
  const shown = sections.map((s) => ({ ...s, cards: s.cards.filter((c) => cardMatches(c, q)) })).filter((s) => s.cards.length);
  return (
    <div className="si" data-testid="settings-index">
      <div className="si__bar">
        <label className="vh" htmlFor="si-q">Find a setting</label>
        <input className="input si__q" id="si-q" type="search" placeholder="Find a setting: fees, reviews, staff, email" value={q} onChange={(e) => setQ(e.target.value)} autoComplete="off" data-testid="settings-search" />
        <nav className="si__jump" aria-label="Settings sections">
          {sections.map((s) => <a key={s.id} href={`#${s.id}`}>{s.title}</a>)}
        </nav>
      </div>
      {shown.length === 0 && <p className="ad-empty" data-testid="settings-none">No setting matches &quot;{q}&quot;. Try one word, for example fees or email.</p>}
      {shown.map((s) => (
        <section key={s.id} id={s.id} className="si__sec" aria-labelledby={`${s.id}-h`} data-testid={`settings-sec-${s.id}`}>
          <header className="si__head"><h2 className="d4" id={`${s.id}-h`}>{s.title}</h2><p className="small muted">{s.about}</p></header>
          <ul className="ad-settings" aria-label={s.title}>{s.cards.map((c) => (
            <li key={c.href}><Link prefetch={false} href={c.href}><span className="ad-settings__mark" aria-hidden="true">{c.title.charAt(0)}</span><b>{c.title}</b><span className="small">{c.about}</span></Link></li>))}</ul>
        </section>
      ))}
    </div>
  );
}
