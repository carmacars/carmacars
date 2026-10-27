import Link from 'next/link';
import { notFound } from 'next/navigation';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { employmentWords, jobPostingLd } from '@/features/careers/model';
import { roleDescription, roleTitle } from '@/features/careers/seo';
import { rolePage } from '@/server/careers';
import { getSettings, photoUrl, siteUrl } from '@/lib/site';

// One role (migration 0173): what it involves, what it needs, the hours and the pay, and Apply. The JobPosting structured data
// follows Google's guidelines: one posting on its own page, the pay only where it is known, remote roles with the countries.
export const revalidate = 300;
export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }) {
  const r = await rolePage((await params).slug);
  if (!r) return seoMeta({ title: 'Role not open | CarmaCars', path: '/careers', noindex: true, description: 'This role is not open. See the roles CarmaCars is hiring for on the careers page.' });
  return seoMeta({ title: roleTitle(r.title), path: `/careers/${r.slug}`, description: roleDescription(r) });
}
export default async function Role({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ slug }, sp] = await Promise.all([params, searchParams]);
  const r = await rolePage(slug);
  if (!r) notFound();
  const s = await getSettings();
  const base = siteUrl();
  const trail: Trail = [['Home', '/'], ['Careers', '/careers'], [r.short_title]];
  const q = new URLSearchParams(Object.entries(sp).filter(([k, v]) => v && (k === 'src' || k.startsWith('utm_'))) as Array<[string, string]>).toString();
  const apply = `/careers/${r.slug}/apply${q ? `?${q}` : ''}`;
  const d = r.details;
  return (
    <div className="p-careers">
      <JsonLd graph={[breadcrumbLd(trail, `/careers/${r.slug}`), jobPostingLd(r, base, { name: s.business?.name || s.brand_name, logo: s.logo.light ? (/^https?:/.test(photoUrl(s.logo.light)) ? photoUrl(s.logo.light) : base + photoUrl(s.logo.light)) : null,
        street: s.business?.street ?? null, city: s.business?.city ?? s.city, region: s.business?.region ?? 'ON', postal: s.business?.postal_code ?? null })]} />
      <PageHead trail={trail} h1={r.title} lead={r.summary} />
      <section className="section" aria-labelledby="cr-role">
        <div className="wrap grid">
          <div className="c-4 stack">
            <h2 className="d3" id="cr-role">At a glance</h2>
            <dl className="cr-facts" data-testid="role-facts">
              <div><dt>Where</dt><dd>{r.location}</dd></div>
              <div><dt>Type</dt><dd>{employmentWords(r.employment_types)}</dd></div>
              <div><dt>Pay</dt><dd>{r.pay_text}</dd></div>
            </dl>
            <p><Link prefetch={false} className="btn btn--primary btn--lg" href={apply} data-testid="role-apply">Apply now</Link></p>
            <p className="small muted">About five minutes. If your answers fit, you book a 15-minute call right away.</p>
          </div>
          <div className="c-8 stack-lg">
            {d.about && <p className="lead">{d.about}</p>}
            {!!d.duties?.length && <><h2 className="d3">What you do</h2><ul className="ticks">{d.duties.map((x) => <li key={x}>{x}</li>)}</ul></>}
            {!!d.requirements?.length && <><h2 className="d3">What you need</h2><ul className="ticks">{d.requirements.map((x) => <li key={x}>{x}</li>)}</ul></>}
            {d.hours && <><h2 className="d3">Hours</h2><p>{d.hours}</p></>}
            <h2 className="d3">Pay</h2>
            {d.pay_detail?.length ? <ul className="ticks" data-testid="role-pay">{d.pay_detail.map((x) => <li key={x}>{x}</li>)}</ul> : <p data-testid="role-pay">{r.pay_text}</p>}
            {d.test_task && <><h2 className="d3">The paid test</h2><p data-testid="role-test">{d.test_task}</p></>}
            <h2 className="d3">How we hire</h2>
            <ol className="ticks ticks--n">
              <li><b>Apply online.</b> A few questions about the role, about five minutes.</li>
              <li><b>Book a call.</b> If your answers fit, you pick a 15-minute call{r.remote ? ' (we show Toronto and Manila time)' : ''}.</li>
              <li><b>Talk to us.</b> {d.test_task ? 'Then the short paid test.' : 'We decide within two days and write to everyone.'}</li>
            </ol>
            <p><Link prefetch={false} className="btn btn--primary btn--lg" href={apply}>Apply for this role</Link></p>
          </div>
        </div>
      </section>
    </div>
  );
}
