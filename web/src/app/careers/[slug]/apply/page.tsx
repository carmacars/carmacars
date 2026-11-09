import Link from '@/components/Link';
import { notFound, redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { ApplyForm } from '@/features/careers/ApplyForm';
import { utmOf } from '@/features/careers/model';
import { closedRole, referralPrefill, rolePage } from '@/server/careers';

// The screening form of one role (migration 0173). ?src=indeed|onlinejobs|referral and the utm_ parameters record where the
// candidate came from; ?ref=<token> (the referral email) fills in their contact details. Not for search engines.
export const dynamic = 'force-dynamic';
export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }) {
  const r = await rolePage((await params).slug);
  return pageMeta({ title: r ? `Apply: ${r.short_title} | CarmaCars` : 'Apply | CarmaCars', path: `/careers/${(await params).slug}/apply`, noindex: true,
    description: 'Apply for a role at CarmaCars, a Toronto car rental company. A few questions about the role; about five minutes.' });
}
export default async function Apply({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ slug }, sp] = await Promise.all([params, searchParams]);
  const r = await rolePage(slug);
  const one = (k: string) => { const v = sp[k]; return (Array.isArray(v) ? v[0] : v) ?? null; };
  if (!r) {
    // 1060: a closed role's application goes to the Sales one, with what was typed
    const c = await closedRole(slug);
    if (!c?.sales) notFound();
    const q = new URLSearchParams({ src: 'referral', from: slug, ...(one('name') ? { name: one('name')! } : {}), ...(one('email') ? { email: one('email')! } : {}) });
    redirect(`/careers/${c.sales.slug}/apply?${q.toString()}`);
  }
  // the referral email's token fills the contact details; else the name and email carried from a filled role's page
  const typed = one('name') || one('email') ? { full_name: (one('name') ?? '').slice(0, 120), email: (one('email') ?? '').slice(0, 200), phone: '', from_role: 'earlier' } : null;
  const prefill = (await referralPrefill(one('ref') ?? undefined, slug)) ?? typed;
  return (
    <div className="p-careers">
      <section className="section">
        <div className="wrap cr-narrow stack-lg">
          <p className="small"><Link prefetch={false} className="link" href={`/careers/${r.slug}`}>{r.title}</Link></p>
          <h1 className="d2">Apply: {r.title}</h1>
          <p className="muted">About five minutes. {r.pay_text}. {r.location}.</p>
          <ApplyForm role={r} src={one('src')} utm={utmOf(sp)} prefill={prefill} refToken={prefill && prefill !== typed ? one('ref') : null} />
        </div>
      </section>
    </div>
  );
}
