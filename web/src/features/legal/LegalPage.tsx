import Link from 'next/link';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, type Trail } from '@/features/seo/meta';
import { block } from '@/lib/site';

export async function LegalPage({ path, h1, lead, body }: { path: string; h1: string; lead: string; body: string }) {
  const trail: Trail = [['Home', '/'], [h1]];
  const meta = (await block('legal.meta'))?.data as { last_updated?: string } | undefined;
  const heads = [...body.matchAll(/<h2 class="d4" id="([^"]+)">(.*?)<\/h2>/g)].map((m) => [m[1]!, m[2]!.replace(/<[^>]+>/g, '')] as const);
  return (
    <div className="p-legal">
      <JsonLd graph={[breadcrumbLd(trail, path)]} />
      <PageHead trail={trail} h1={h1} lead={lead} />
      <section className="section">
        <div className="wrap grid">
          <aside className="c-4"><div className="how__sticky stack-lg">
            {meta?.last_updated && <p className="small muted">Last updated {meta.last_updated}.</p>}
            {heads.length > 0 && <nav aria-label="Sections"><ul className="toc">{heads.map(([id, t]) => <li key={id}><a href={`#${id}`}>{t}</a></li>)}</ul></nav>}
            <ul className="toc toc--plain"><li><Link href="/terms">Terms of use</Link></li><li><Link href="/privacy">Privacy policy</Link></li><li><Link href="/cancellation-policy">Cancellation policy</Link></li></ul>
          </div></aside>
          <article className="c-8 prose" dangerouslySetInnerHTML={{ __html: body }} />
        </div>
      </section>
    </div>
  );
}
