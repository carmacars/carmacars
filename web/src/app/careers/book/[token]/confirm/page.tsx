import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { ConfirmCall } from '@/features/careers/ConfirmCall';

// "Confirm my call" (migration 0229): the link of the confirmation email a remote role's candidate gets 24 hours before
// the call. One press confirms, no sign-in. The press is a button, not the link itself, so a mail scanner opening links
// never confirms a call the candidate did not.
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Confirm your interview call | CarmaCars', path: '/careers/book', noindex: true,
  description: 'Confirm your CarmaCars interview call in one press.' });
export default async function Confirm({ params, searchParams }: { params: Promise<{ token: string }>; searchParams: Promise<{ seq?: string }> }) {
  const [{ token }, sp] = await Promise.all([params, searchParams]);
  const seq = /^\d{1,6}$/.test(sp.seq ?? '') ? Number(sp.seq) : null;
  return (
    <div className="p-careers">
      <section className="section">
        <div className="wrap cr-narrow stack-lg">
          <h1 className="d2">Confirm your interview call</h1>
          <ConfirmCall token={token} seq={seq} />
          <p className="small"><Link prefetch={false} className="link" href={`/careers/book/${token}`}>See or change your call</Link></p>
        </div>
      </section>
    </div>
  );
}
