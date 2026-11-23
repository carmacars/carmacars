import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { GiftCardFace } from '@/features/gift-cards/GiftCardFace';
import { PrintButton } from '@/features/gift-cards/PrintButton';
import '@/features/gift-cards/gift-cards.css';

// The printable gift card (migration 3600): the link in the recipient's email and on the buyer's thank-you screen. The
// token is the card's secret (64 characters); the page is never indexed. Print, or save as PDF from the print dialog.
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your CarmaCars gift card', path: '/gift-cards', noindex: true, description: 'Print your CarmaCars gift card or save it as a PDF.' });

interface View { code: string; initial_cents: number; balance_cents: number; kind_label: string; recipient_name: string; from_name: string; message: string | null; rental_text: string | null; expires_at: string | null }

export default async function GiftCardPrint({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  if (!/^[0-9a-f]{64}$/.test(token)) notFound();
  const g = (await rpc('server_gift_card_view', { p_token: token }, { role: 'service_role' }).catch(() => null)) as unknown as View | null;
  if (!g) notFound();
  return (
    <section className="section">
      <div className="wrap gc-print" data-testid="gift-print-page">
        <GiftCardFace amountCents={g.initial_cents} to={g.recipient_name} kindLabel={g.kind_label} code={g.code} rentalText={g.rental_text} />
        {g.message && <p className="gc-print__msg">&ldquo;{g.message}&rdquo; <br /><span className="small muted">From {g.from_name}</span></p>}
        <div className="gc-print__how">
          <p><b>How to use it.</b> Sign in or create your account at carmacars.ca, open Gift cards and add the code. When you sign and pay for a booking, the balance is used before your card; what is left stays on the gift card.</p>
          <p>{g.expires_at ? `This voucher ends on ${new Date(g.expires_at).toLocaleDateString('en-CA', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'America/Toronto' })}.` : 'It never expires.'} It pays the rental, its fees and the HST, never the refundable deposit.</p>
        </div>
        <div className="gc-print__actions row"><PrintButton /><Link prefetch={false} className="btn btn--ghost" href={`/account/gift-cards?code=${encodeURIComponent(g.code)}`}>Add it to my account</Link></div>
      </div>
    </section>
  );
}
