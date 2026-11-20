import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { salesOffer } from '@/server/sales-yes';
import { salesYesAction } from '@/server/actions/sales-yes';

// r48 FE (3191): the one click of the Sales referral. No new form: the Sales application is made from the one the
// applicant sent, and the AI interview link goes to them at once (and opens here).
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Join our Sales team | CarmaCars', path: '/careers/sales-yes', noindex: true,
  description: 'One click puts your application in Sales at CarmaCars, with what you already sent us, and opens your video interview.' });
export default async function SalesYesPage({ params, searchParams }: { params: Promise<{ token: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ token }, sp] = await Promise.all([params, searchParams]);
  const v = await salesOffer(token);
  return (
    <div className="p-careers">
      <section className="section">
        <div className="wrap cr-narrow stack-lg" data-testid="sales-yes">
          {!v ? <><h1 className="d2">This link is not valid</h1><p>Open the link in our email again, or reply to that email and we will help.</p><p><Link prefetch={false} className="link" href="/careers">Open roles</Link></p></>
            : v.done ? <><h1 className="d2">You are in for Sales, {v.first_name}</h1>
                <p>{v.interview_url ? 'Your video interview is open: it takes about 10 minutes.' : v.interview_state === 'scored' || v.interview_state === 'submitted' ? 'Your interview is done: we email you the result.' : 'We email you the next step.'}</p>
                {v.interview_url && <p><a className="btn btn--primary" href={new URL(v.interview_url).pathname} data-testid="sales-yes-interview">Start the interview</a></p>}</>
            : <>
                <h1 className="d2">{v.first_name}, join our Sales team</h1>
                <p>You applied for {v.from_role ?? 'a role'} with us. We think you would do well as our <b>{v.sales_role}</b>.</p>
                {v.sales_summary && <p className="muted">{v.sales_summary}</p>}
                <p>One click is all: we use what you already sent us (no new form) and your video interview opens straight away. We also email you the link.</p>
                {sp.error && <p className="alert alert--error" role="alert"><span>{sp.error}</span></p>}
                <form action={salesYesAction}><input type="hidden" name="token" value={token} />
                  <button className="btn btn--primary" type="submit" data-testid="sales-yes-button">Yes, put me in Sales</button></form>
                <p className="small muted">Not for you? There is nothing to do.</p>
              </>}
        </div>
      </section>
    </div>
  );
}
