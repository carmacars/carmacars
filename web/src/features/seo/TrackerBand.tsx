import Link from '@/components/Link';
import { money } from '@/lib/format';
import { getTrackerProduct } from '@/features/tracker-product/data';

// The GPS tracker section of every search page (release 36, part 7): its name, price and first features from Program
// settings, linking to /gps-tracker. Nothing shows when the product is switched off.
export async function TrackerBand() {
  const t = await getTrackerProduct();
  if (!t) return null;
  return (
    <section className="car-sec landing__sec" aria-labelledby="h-tracker" data-testid="tracker-band">
      <h2 className="d2" id="h-tracker">For car owners: the {t.name}</h2>
      <p className="measure">{t.features.slice(0, 3).map((f) => `${f.title}: ${f.text}`).join(' ')}{t.monthly_cents ? ` From ${money(t.monthly_cents)} a month.` : ''}</p>
      <p><Link prefetch={false} className="link link--go" href="/gps-tracker">See the GPS tracker</Link></p>
    </section>
  );
}
