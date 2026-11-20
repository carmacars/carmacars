import Link from '@/components/Link';
import { seoMeta } from '@/features/seo/meta';
import { metaOr } from '@/features/seo/meta-fallback';
import { TrackerTemplate, loadTracker, trackerFacts } from '@/features/trackers/TrackerPage';
import { getInstallPlaces } from '@/features/tracker-product/data';
import { installSentence, productFaq } from '@/features/trackers/pages';
import { money } from '@/lib/format';

// "GPS tracker install near me" (release 48): how the install goes and the Ontario cities with their own page.
export const dynamic = 'force-dynamic';

export async function generateMetadata() {
  return metaOr(async () => {
    const x = await trackerFacts();
    if (!x) return {};
    return seoMeta({ title: `GPS Tracker and Kill Switch Installation Near You in Ontario | ${x.f.brand}`,
      description: `${x.f.brand} installs the ${x.f.name} out of sight and checks that it works. ${installSentence(x.f).replace(/^./, (c) => c.toUpperCase())}. Find your city.`.slice(0, 160), path: '/trackers/install' });
  }, { title: 'GPS tracker installation' }, (m) => console.warn('tracker install', m));
}

export default async function Page() {
  const { f } = await loadTracker();
  const places = await getInstallPlaces(120);
  return (
    <TrackerTemplate path="/trackers/install" testId="tracker-install-hub" trail={[['Home', '/'], [f.name, '/trackers'], ['Install near you']]} kicker="Installation" icon="wrench" facts={f}
      h1="GPS tracker and kill switch installation near you"
      answer={`${f.brand} installs the ${f.name} for car owners in ${f.city} and the cities around it. The install is ${f.installCents ? `${money(f.installCents)} once per car` : 'quoted for your car'}: the tracker goes in out of sight and we check the location, the starter interrupt, the locks and the alarm before the car goes back out.`}
      own={{ h: 'How the install goes', p: 'One visit per car.', steps: [['We agree the day and place', 'Tell us where the car is when you join the waitlist.'], ['The tracker goes in', 'Out of sight, wired to the starter.'],
        ['We test it with you', 'Location, starter interrupt, locks and alarm, on your phone.'], ['The car goes back out', 'Tracked from that minute.']] }}
      faq={productFaq(f).filter((q) => /install|today|car\?|much/i.test(q.question))} lead={['Installed', 'Kill switch', 'Live GPS']}
      places={places.map((p) => ({ href: `/trackers/install/${p.slug}`, label: `Tracker install in ${p.name}` }))} placesTitle="Find your city"
      placeNote={places.length === 0 ? <p className="small muted">Tell us your city on the form and we confirm the install for you. <Link prefetch={false} className="link" href="/contact">Contact us</Link></p> : undefined} />
  );
}
