import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { BookingPicker } from '@/features/careers/BookingPicker';
import { bookingView } from '@/server/careers';

// The candidate's booking page (migration 0173): their personal link from the invitation. Pick, move or cancel the interview call.
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Book your interview call | CarmaCars', path: '/careers/book', noindex: true,
  description: 'Pick a time for your interview call with CarmaCars, or move or cancel the call you booked. Times are shown in Toronto time.' });
export default async function Book({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const v = await bookingView(token);
  return (
    <div className="p-careers">
      <section className="section">
        <div className="wrap cr-narrow stack-lg">
          {!v
            ? <><h1 className="d2">This link is not valid</h1><p>It may be incomplete. Open the link in our email again, or reply to that email and we will help.</p><p><Link prefetch={false} className="link" href="/careers">Open roles</Link></p></>
            : <BookingPicker token={token} v={v} />}
        </div>
      </section>
    </div>
  );
}
