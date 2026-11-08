import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { bookingPath } from '@/features/portal/status';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign and pay', path: '/account/bookings', noindex: true, description: 'Sign the rental agreement and pay for your booking.' });

// r33: signing and paying are one page (Sign and pay, ../checkout). This address stays for the emails, texts and
// bookmarks that link to it: it lands on that page, at the signature, with its query (a card's 3-D Secure return).
export default async function SignRedirect({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const n = decodeURIComponent((await params).number);
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(await searchParams)) for (const x of Array.isArray(v) ? v : v === undefined ? [] : [v]) q.append(k, x);
  const qs = q.toString();
  redirect(`${bookingPath(n, 'checkout')}${qs ? `?${qs}` : ''}#sign`);
}
