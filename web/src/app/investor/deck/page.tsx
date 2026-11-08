import '@/styles/deck.css';
import Link from '@/components/Link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf } from '@/server/door';
import { PitchDeck } from '@/features/deck/PitchDeck';
import { PER_CAR } from '@/features/deck/pitch';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'CarmaCars investor deck', path: '/investor/deck', noindex: true, description: 'The CarmaCars investor presentation, 2026.' });

// The investor deck (r35: the 2026 pitch deck, slide by slide, as responsive HTML; features/deck/pitch.ts): signed-in
// investors while Admin > Investors > Deck has "Show the deck to investors" on (migration 0851 turns it on), and Admins
// always. Everyone else is sent away; the database checks the same (deck_visible). The multiplier is the Admin's figure.
export default async function InvestorDeck() {
  const user = await currentUser();
  if (!user) redirect('/sign-in?next=/investor/deck');
  const roles = await rolesOf(user.id);
  if (!roles.investor && !roles.admin) redirect('/investor/no-access');
  const shown = roles.admin ? true : await door<{ visible: boolean }>(user.id, 'investor_read', 'deck_visible').then((r) => r.visible).catch(() => false);
  if (!shown) {
    return <section className="pt-card" data-testid="deck-closed"><h1 className="d3">The investor deck is not available yet</h1>
      <p>We will let you know when it is ready. Your investments and statements are on <Link className="link" href="/investor">Investments</Link>.</p></section>;
  }
  const mult = await door<{ settings: { deck_multiplier: number | string } }>(user.id, roles.investor ? 'investor_read' : 'admin_read', roles.investor ? 'deck' : 'investor_deck')
    .then((f) => Number(f.settings.deck_multiplier)).catch(() => PER_CAR.multiplier);
  return <div className="dk-bleed"><h1 className="vh">CarmaCars investor deck</h1><PitchDeck multiplier={mult > 0 ? mult : PER_CAR.multiplier} /></div>;
}
