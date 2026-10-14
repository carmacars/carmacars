import Link from 'next/link';
import { CtaBand, PageHead } from '@/components/Blocks';
import { Faq } from '@/components/Faq';
import { FaqFilter } from '@/components/FaqFilter';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, faqLd, type Trail, seoMeta } from '@/features/seo/meta';
import { faqItems, fill, getBlocks, getTokens } from '@/lib/site';
import type { FaqItem } from '@/lib/types';

export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['FAQ']];

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('FAQ: renting a car from {{brand}} in {{city}}', t), path: '/faq',
    description: fill('Answers about booking, age and licence rules, coverage, deposits, delivery, kilometres, tolls, cancelling and listing your car with {{brand}}.', t) });
}

export default async function FaqPage() {
  const [t, blocks, owner] = await Promise.all([getTokens(), getBlocks(), faqItems('owners.faq')]);
  const F = (x: string) => fill(x, t);
  const groups = blocks.filter((b) => b.page === 'faq' && b.kind === 'faq')
    .map((b) => ({ title: b.body ?? '', id: String(b.data.id), items: (b.data.items as FaqItem[]).map((q) => ({ question: F(q.question), answer: F(q.answer) })) }));
  const ownerGroup = groups.find((g) => g.id === 'owners');
  if (ownerGroup && !ownerGroup.items.length) ownerGroup.items = owner.slice(0, 5).map((q) => ({ question: F(q.question), answer: F(q.answer) }));
  return (
    <div className="p-faq">
      <JsonLd graph={[breadcrumbLd(trail, '/faq'), faqLd(groups.flatMap((g) => g.items))]} />
      <PageHead trail={trail} h1="Straight answers." lead="Sorted by topic. Type a word to narrow them down." />
      <section className="section">
        <div className="wrap grid">
          <aside className="c-4"><div className="how__sticky stack-lg">
            <FaqFilter />
            <nav aria-label="Topics"><ul className="toc">{groups.map((g) => <li key={g.id}><a href={`#${g.id}`}>{g.title}</a></li>)}</ul></nav>
          </div></aside>
          <div className="c-8 stack-lg">
            {groups.map((g) => (
              <section key={g.id} id={g.id} data-faq-group aria-labelledby={`fq-${g.id}`} className="stack">
                <h2 className="d3" id={`fq-${g.id}`}>{g.title}</h2>
                <Faq items={g.items} />
              </section>
            ))}
            <div className="empty" data-faq-none hidden><p className="d3">Nothing matches that.</p><p className="muted">Try one word, like “deposit”. Or <Link className="link" href="/contact">ask us directly</Link>.</p></div>
          </div>
        </div>
      </section>
      <CtaBand h="Ask a person." p="We would rather answer now than surprise you later." btn={['Contact us', '/contact']} />
    </div>
  );
}
