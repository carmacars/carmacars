import Link from 'next/link';
import { CtaBand, PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { employmentWords } from '@/features/careers/model';
import { openRoles } from '@/server/careers';

// Careers (migration 0173): the open roles. With none open the page says so and stays out of search and the sitemap.
export const revalidate = 300;
export async function generateMetadata() {
  const roles = await openRoles();
  return seoMeta({ title: 'Careers at CarmaCars | Jobs in Toronto and remote', path: '/careers', noindex: roles.length === 0,
    description: 'Work with CarmaCars, a Toronto car rental company: field staff, sales and customer relations, and remote roles. Apply online in about five minutes.' });
}
export default async function Careers() {
  const roles = await openRoles();
  const trail: Trail = [['Home', '/'], ['Careers']];
  return (
    <div className="p-careers">
      <JsonLd graph={[breadcrumbLd(trail, '/careers')]} />
      <PageHead trail={trail} h1="Careers at CarmaCars." lead="We are a Toronto car rental company with a small team. Apply online in about five minutes: we reply to every applicant." />
      <section className="section" aria-labelledby="cr-open">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="cr-open">Open roles</h2><p className="muted">Pick a role to read what it involves, then apply.</p></div>
          <div className="c-8 stack-lg">
            {roles.length === 0
              ? <p className="lead" data-testid="careers-none">No roles are open right now. Please check back soon.</p>
              : <ul className="cr-roles" data-testid="careers-roles">
                  {roles.map((r) => (
                    <li key={r.slug} className="cr-role">
                      <h3 className="d3"><Link prefetch={false} className="link" href={`/careers/${r.slug}`} data-testid={`role-${r.slug}`}>{r.title}</Link></h3>
                      <p>{r.summary}</p>
                      <p className="small muted">{r.location} · {employmentWords(r.employment_types)} · {r.pay_text}</p>
                    </li>
                  ))}
                </ul>}
            <p className="small muted measure">How it works: you answer a few questions about the role, and if your answers fit, you book a 15-minute call straight away. We decide within two days of the call.</p>
          </div>
        </div>
      </section>
      <CtaBand h="Renting a car?" p="Browse the fleet, then send a request. A person confirms the car and the price." />
    </div>
  );
}
