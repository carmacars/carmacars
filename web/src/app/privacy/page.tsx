import { LegalPage } from '@/features/legal/LegalPage';
import { legalHtml } from '@/features/legal/render';
import { pageMeta } from '@/features/seo/meta';
import { fill, getTokens } from '@/lib/site';

export const revalidate = 3600;
export async function generateMetadata() {
  const t = await getTokens();
  return pageMeta({ title: fill('Privacy policy | {{brand}}', t), path: '/privacy', description: fill('What personal information {{brand}} collects, why, who it is shared with, how long it is kept, and how GPS tracking works during a rental.', t) });
}
export default async function Privacy() {
  return <LegalPage path="/privacy" h1="Privacy policy" lead="What we collect, why we need it, and what you can ask us to do with it." body={await legalHtml('legal.privacy')} />;
}
