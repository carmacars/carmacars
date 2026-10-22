import '@/styles/deck.css';
import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { PageHead } from '@/features/admin/ui';
import { Deck } from '@/features/deck/Deck';
import type { DeckFigures } from '@/features/deck/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Investor deck preview', path: '/admin/investors/deck', noindex: true, description: 'Preview and settings of the investor deck.' });

const torontoToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

// The Admin's preview of the investor deck and its settings (migration 0083): shown to investors or not, the company's
// multiplier figure and the yearly percentage of the current offer used by the examples and the calculator.
export default async function AdminDeck() {
  const { read } = await page('/admin/investors/deck');
  const f = await read<DeckFigures>('investor_deck');
  const st = f.settings;
  return (<>
    <PageHead title="Investor deck"><Link className="btn btn--ghost btn--sm" href="/investor/deck" prefetch={false}>Open as investors see it</Link></PageHead>
    <section className="ad-card" aria-labelledby="dk-set" data-testid="deck-settings">
      <h2 className="d4" id="dk-set">Settings</h2>
      <p className="small" data-testid="deck-visibility">{st.show_to_investors ? 'Investors see the deck in their portal now.' : 'Hidden from investors. Only Admins see it.'}{st.updated_by ? ` Last changed by ${st.updated_by}.` : ''}</p>
      <Act inline action="deck_settings_save" label="Save deck settings" testId="deck-save" done="Saved." refresh={['/admin/investors/deck', '/investor/deck', '/investor']} fields={[
        { name: 'show_to_investors', label: 'Show the deck to investors', type: 'bool', value: st.show_to_investors, hint: 'Signed-in investors see it under Investor deck in their portal.' },
        { name: 'deck_multiplier', label: 'Multiplier on the money we invest (x)', type: 'number', value: Number(st.deck_multiplier), min: 0.01, max: 99.99, required: true,
          hint: 'The company\'s own figure, shown as "3.2x" with its footnote (internal, not audited).' },
        { name: 'deck_return_bps', label: 'Yearly percentage of the current offer', type: 'percent', value: st.deck_return_bps, required: true,
          hint: 'Used by the worked examples and the calculator only. Each investor\'s percentage is the one in their agreement.' }
      ]} />
    </section>
    <p className="dk-preview-note small">Preview: this is the deck exactly as investors see it, with today&apos;s figures from the database.</p>
    <div className="dk-admin-preview"><Deck f={f} today={torontoToday()} /></div>
  </>);
}
