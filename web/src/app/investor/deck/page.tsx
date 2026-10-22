import '@/styles/deck.css';
import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf } from '@/server/door';
import { Deck } from '@/features/deck/Deck';
import type { DeckFigures } from '@/features/deck/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'CarmaCars investor deck', path: '/investor/deck', noindex: true, description: 'The CarmaCars investor deck.' });

const torontoToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

// The investor deck (migration 0083): signed-in investors while Admin > Investors > Deck has "Show the deck to investors"
// on, and Admins always. Everyone else is sent away; the database checks the same (app.deck_read).
export default async function InvestorDeck() {
  const user = await currentUser();
  if (!user) redirect('/sign-in?next=/investor/deck');
  const roles = await rolesOf(user.id);
  if (!roles.investor && !roles.admin) redirect('/investor/no-access');
  let f: DeckFigures | null = null;
  try {
    f = roles.investor ? await door<DeckFigures>(user.id, 'investor_read', 'deck') : await door<DeckFigures>(user.id, 'admin_read', 'investor_deck');
  } catch (e) {
    if (!/not open yet/i.test(String((e as Error)?.message ?? e))) throw e;
  }
  if (!f) {
    return <section className="pt-card" data-testid="deck-closed"><h1 className="d3">The investor deck is not available yet</h1>
      <p>We will let you know when it is ready. Your investments and statements are on <Link className="link" href="/investor">Investments</Link>.</p></section>;
  }
  return <div className="dk-bleed"><h1 className="vh">CarmaCars investor deck</h1><Deck f={f} today={torontoToday()} /></div>;
}
