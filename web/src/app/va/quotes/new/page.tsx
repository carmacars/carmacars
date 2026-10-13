import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { QuoteForm } from '@/features/va/QuoteForm';
import { Card, PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'New quote', path: '/va/quotes/new', noindex: true, description: 'A request from a phone, email or WhatsApp lead.' });

// Sales quotes (05-va.md section 5): the request first, then the offer from the review screen. Only the
// non-refundable saving and an existing promo code may be offered; no discount field.
export default async function NewQuote() {
  const { read } = await vaPage('/va/quotes/new', ['sales', 'cs']);
  const f = await read<{ vehicles: Array<{ id: string; name: string }>; min_notice_minutes: number }>('quote_form');
  return (<><PageHead title="New quote" /><Card title="The lead and the trip"><QuoteForm vehicles={f.vehicles} minNotice={f.min_notice_minutes} /></Card></>);
}
