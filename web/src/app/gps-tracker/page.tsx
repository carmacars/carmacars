import { notFound } from 'next/navigation';
import { SeoShell } from '@/features/seo/Shell';
import { seoMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { getSettings } from '@/lib/site';
import { getTrackerProduct } from '@/features/tracker-product/data';

// The GPS tracker product page (release 36, part 7; migration 2003): everything from Program settings (name, prices,
// features, details). Switched off: 404. Edge copy only (src/lib/edge/page-cache.ts PROGRAMMATIC).
export const dynamic = 'force-dynamic';

export async function generateMetadata() {
  const t = await getTrackerProduct();
  if (!t) return {};
  return seoMeta({ title: `${t.name}: live location and trip history`, description: `${t.name}: ${t.features.slice(0, 2).map((f) => f.text).join(' ')}${t.monthly_cents ? ` From ${money(t.monthly_cents)} a month.` : ''}`.slice(0, 160), path: '/gps-tracker' });
}

export default async function Page() {
  const [t, s] = await Promise.all([getTrackerProduct(), getSettings()]);
  if (!t) notFound();
  const price = t.monthly_cents ? `${money(t.monthly_cents)} a month` : 'Quoted for your car';
  const install = t.install_cents ? money(t.install_cents) : 'Quoted for your car';
  return (
    <SeoShell path="/gps-tracker" testId="gps-tracker" trail={[['Home', '/'], [t.name]]} h1={t.name} hideTracker
      lead={[`A GPS tracker for your car, installed by ${s.brand_name}: ${t.features.map((f) => f.title.toLowerCase()).join(', ')}.`, t.details ?? '']}
      facts={[['Monthly', price], ['Install', install]]}
      faq={[{ question: `How much is the ${t.name}?`, answer: `${price}${t.install_cents ? `, plus ${install} to install` : ''}.` },
        { question: 'Who installs it?', answer: `${s.brand_name} installs it and checks it works.` }]}
      ld={[{ '@type': 'Product', name: t.name, description: t.features.map((f) => f.text).join(' '), brand: { '@type': 'Brand', name: s.brand_name },
        ...(t.monthly_cents ? { offers: { '@type': 'Offer', price: (t.monthly_cents / 100).toFixed(2), priceCurrency: 'CAD', priceSpecification: { '@type': 'UnitPriceSpecification', price: (t.monthly_cents / 100).toFixed(2), priceCurrency: 'CAD', unitCode: 'MON' } } } : {}) }]}
      links={[{ href: '/list-your-car', label: 'List your car with us' }, { href: '/contact?topic=tracker', label: 'Ask about the tracker' }]}
      cta={{ h: 'Want a tracker in your car?', p: 'Ask us: we reply with the price for your car.' }}>
      <section className="car-sec landing__sec" aria-labelledby="h-features">
        <h2 className="d2" id="h-features">What it does</h2>
        <ul className="linklist">{t.features.map((f) => <li key={f.title}><p><b>{f.title}</b></p><p className="small">{f.text}</p></li>)}</ul>
      </section>
    </SeoShell>
  );
}
