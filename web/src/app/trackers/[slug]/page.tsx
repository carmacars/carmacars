import { notFound } from 'next/navigation';
import { seoMeta } from '@/features/seo/meta';
import { metaOr, titleFromPath } from '@/features/seo/meta-fallback';
import { TrackerTemplate, installLinks, loadTracker, trackerFacts } from '@/features/trackers/TrackerPage';
import { trackerIntents } from '@/features/trackers/pages';

// One page per way people search for the tracker (release 48): kill switch, starter interrupt, rental car tracker,
// anti-theft, fleet tracking, Turo hosts, tolls and tickets (src/features/trackers/pages.ts). An address that is none
// of them answers 404.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ slug: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug } = await params;
  return metaOr(async () => {
    const x = await trackerFacts();
    const i = x ? trackerIntents(x.f).find((p) => p.slug === slug) : null;
    if (!i) return {};
    return seoMeta({ title: i.title, description: i.answer.slice(0, 158).replace(/\s+\S*$/, ''), path: `/trackers/${i.slug}` });
  }, { title: titleFromPath(`/trackers/${slug}`) }, (m) => console.warn('tracker intent', m));
}

export default async function Page({ params }: Params) {
  const { slug } = await params;
  if (!/^[a-z0-9-]{3,60}$/.test(slug)) notFound();
  const { f } = await loadTracker();
  const i = trackerIntents(f).find((p) => p.slug === slug);
  if (!i) notFound();
  return (
    <TrackerTemplate path={`/trackers/${i.slug}`} testId="tracker-intent" trail={[['Home', '/'], [f.name, '/trackers'], [i.kicker]]} kicker={i.kicker} icon={i.icon} facts={f}
      h1={i.h1} answer={i.answer} own={i.section} compare={i.compare} faq={i.faq} lead={i.lead} places={await installLinks(12)} />
  );
}
