import { LegalPage } from '@/features/legal/LegalPage';
import { legalHtml } from '@/features/legal/render';
import { seoMeta } from '@/features/seo/meta';
import { fill, getTokens } from '@/lib/site';

export const revalidate = 3600;
export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Terms of use | {{brand}}', t), path: '/terms', description: fill('The terms that apply to everyone who uses the {{brand}} website and its renter, owner and staff portals.', t) });
}
export default async function Terms() {
  const [terms, cancel] = await Promise.all([legalHtml('legal.terms'), legalHtml('legal.cancellation')]);
  // Emails link to /terms#cancellation (emails/src/links.mjs): the refund summary follows the terms.
  const body = `${terms}<h2 class="d4" id="cancellation">Cancellation and refunds</h2>${cancel}`;
  return <LegalPage path="/terms" h1="Terms of use" lead="The rules for using this site. Each rental is governed by the rental agreement you sign for it." body={body} />;
}
