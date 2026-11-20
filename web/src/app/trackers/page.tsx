import { seoMeta } from '@/features/seo/meta';
import { metaOr } from '@/features/seo/meta-fallback';
import { TrackerTemplate, installLinks, loadTracker, trackerFacts } from '@/features/trackers/TrackerPage';
import { lowest, monthly, productAnswer, productFaq } from '@/features/trackers/pages';

// The GPS tracker and kill switch product page (release 48, migration 3231; it replaces /gps-tracker, which answers 308
// here). Everything from Program settings; switched off: 404. Rendered on demand and kept in the edge copy a day
// (src/lib/edge/page-cache.ts PROGRAMMATIC).
export const dynamic = 'force-dynamic';

export async function generateMetadata() {
  return metaOr(async () => {
    const x = await trackerFacts();
    if (!x) return {};
    const lo = lowest(x.f);
    return seoMeta({ title: `GPS Tracker and Kill Switch for Cars in ${x.f.city}${lo !== null ? `, from ${monthly(lo)}` : ''} | ${x.f.brand}`,
      description: `${x.f.name}: live GPS, a remote kill switch (starter interrupt), door locking and an alarm from your phone. ${lo !== null ? `From ${monthly(lo)} per car. ` : ''}${x.f.available ? 'Installs are open.' : 'Join the waitlist or pre-order.'}`.slice(0, 160), path: '/trackers' });
  }, { title: 'GPS tracker and kill switch' }, (m) => console.warn('trackers', m));
}

export default async function Page() {
  const { f } = await loadTracker();
  return (
    <TrackerTemplate path="/trackers" testId="trackers" trail={[['Home', '/'], [f.name]]} kicker="GPS tracker and kill switch" icon="pin" facts={f}
      h1="GPS tracker and kill switch for your car" answer={productAnswer(f)} faq={productFaq(f)} lead={['Live GPS', 'Kill switch', 'Remote lock']}
      own={{ h: 'How it works', p: 'From the list to a car you can see.', steps: [['Join the waitlist', 'Your email and the number of cars. Nothing is charged.'], ['We confirm your price', 'In writing, for your cars, before anything is billed.'],
        ['We install it', 'Out of sight, and we check that it works.'], ['You see your car', 'Live on the map, with the kill switch, the locks and the alarm on your phone.']] }}
      compare={{ caption: 'What you get compared with other ways to protect a car', head: ['', f.name, 'Plug-in OBD tracker', 'Bluetooth tag', 'Hidden toggle kill switch'],
        rows: [['Live GPS location', 'Yes', 'Yes', 'Only near a phone on its network', 'No'], ['Remote kill switch (starter interrupt)', 'Yes', 'No', 'No', 'By hand, at the car'], ['Remote door locking', 'Yes', 'No', 'No', 'No'],
          ['Alarm from your phone', 'Yes', 'No', 'A beep at the tag', 'No'], ['Trip history with times and route', 'Yes', 'On some', 'No', 'No'], ['Installed out of sight', `Yes, by ${f.brand}`, 'Plugs into a visible port', 'Hidden by you', 'By an installer']] }}
      places={await installLinks(24)} placesTitle="Tracker install near you" />
  );
}
