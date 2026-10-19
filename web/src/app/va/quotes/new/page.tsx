import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { QuoteForm } from '@/features/va/QuoteForm';
import { Card, PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'New quote', path: '/va/quotes/new', noindex: true, description: 'A request from a phone, email or WhatsApp lead.' });

// Quotes (05-va.md section 5; every assistant function since 0058): the request first, then the offer from the review
// screen. A price may be typed with its reason; the choice "I sourced this client" or "Entered for CarmaCars" is required.
export default async function NewQuote() {
  const { read } = await vaPage('/va/quotes/new');
  const f = await read<{ vehicles: Array<{ id: string; name: string }>; min_notice_minutes: number; price_floor_daily_cents: number | null; price_max_discount_bps: number | null }>('quote_form');
  return (<><PageHead title="New quote" /><Card title="The lead and the trip"><QuoteForm vehicles={f.vehicles} minNotice={f.min_notice_minutes} /></Card></>);
}
