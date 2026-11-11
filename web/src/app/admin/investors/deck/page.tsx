import '@/styles/deck.css';
import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { PageHead } from '@/features/admin/ui';
import { PitchDeck } from '@/features/deck/PitchDeck';
import type { DeckFigures } from '@/features/deck/types';
import { SearchTraction } from '@/features/deck/SearchTraction';
import type { DeckSearch } from '@/features/deck/search';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Investor deck preview', path: '/admin/investors/deck', noindex: true, description: 'Preview and settings of the investor deck.' });

// The Admin's preview of the investor deck and its settings (migration 0083; r35: the 2026 pitch deck, features/deck/pitch.ts):
// shown to investors or not, the company's multiplier figure on the Per car slide, and the yearly percentage the Live
// sheets calculator starts from.
export default async function AdminDeck() {
  const { read } = await page('/admin/investors/deck');
  const f = await read<DeckFigures>('investor_deck');
  const st = f.settings;
  const search = await read<DeckSearch>('deck_search').catch(() => null);
  return (<>
    <PageHead title="Investor deck"><Link className="btn btn--ghost btn--sm" href="/investor/deck" prefetch={false}>Open as investors see it</Link></PageHead>
    <section className="ad-card" aria-labelledby="dk-set" data-testid="deck-settings">
      <h2 className="d4" id="dk-set">Settings</h2>
      <p className="small" data-testid="deck-visibility">{st.show_to_investors ? 'Investors see the deck in their portal now.' : 'Hidden from investors. Only Admins see it.'}{st.updated_by ? ` Last changed by ${st.updated_by}.` : ''}</p>
      <Act inline action="deck_settings_save" label="Save deck settings" testId="deck-save" done="Saved." refresh={['/admin/investors/deck', '/investor/deck', '/investor']} fields={[
        { name: 'show_to_investors', label: 'Show the deck to investors', type: 'bool', value: st.show_to_investors, hint: 'Signed-in investors see it under Investor deck in their portal.' },
        { name: 'deck_multiplier', label: 'Multiplier on the money we invest (x)', type: 'number', value: Number(st.deck_multiplier), min: 0.01, max: 99.99, required: true,
          hint: 'The company\'s own figure on the Per car slide, shown as "3.2x" with its footnote (internal and unaudited).' },
        { name: 'deck_return_bps', label: 'Yearly percentage of the current offer', type: 'percent', value: st.deck_return_bps, required: true,
          hint: 'The Live sheets calculator starts from it for an investor without an agreement. The deck states the terms of the raise (10 to 15% a year, or a 20 to 25% profit share). Each investor\'s percentage is the one in their agreement.' }
      ]} />
    </section>
    <section className="ad-card" aria-labelledby="dk-sc" data-testid="deck-search-settings">
      <h2 className="d4" id="dk-sc">Search Console on the deck</h2>
      <p className="small">Clicks and impressions come from Search Console by itself (the gsc workflow, every few hours). Indexed pages have no API: type the figure from Search Console &gt; Indexing &gt; Pages{search?.indexed_on ? ` (last typed ${search.indexed_on})` : search?.indexed_estimate ? ' (an estimate from a sample shows until you do)' : ''}.</p>
      <Act inline action="deck_search_indexed" label="Save indexed pages" testId="deck-search-indexed-save" done="Saved." refresh={['/admin/investors/deck', '/investor/deck']}
        fields={[{ name: 'indexed_pages', label: 'Indexed pages (Search Console)', type: 'text', required: true, value: search?.indexed_pages && !search.indexed_estimate ? String(search.indexed_pages) : '' }]} />
    </section>
    <p className="dk-preview-note small">Preview: this is the deck exactly as investors see it, with today&apos;s figures from the database.</p>
    <div className="dk-admin-preview"><PitchDeck multiplier={Number(st.deck_multiplier) > 0 ? Number(st.deck_multiplier) : undefined} /><SearchTraction s={search} /></div>
  </>);
}
