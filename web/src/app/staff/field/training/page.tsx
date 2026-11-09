import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { requireStaff } from '@/server/door';
import { academyHome } from '@/server/academy';
import { FdIcon } from '@/features/field/icons';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Training', path: '/staff/field/training', noindex: true, description: 'Your academy paths and the field guide.' });

// Training (r35 part X): the academy paths (field, and Sales for a person who opted in), section by section with what is passed,
// and the field guide. The academy itself opens at /staff/academy.
export default async function Training() {
  const { user } = await requireStaff('field', '/staff/field/training');
  const h = await academyHome(user.id).catch(() => null);
  return (
    <>
      <header className="fp-hello"><h1>Training</h1><p>{h?.locked ? 'Pass the academy to start work' : 'Keep your skills fresh'}</p></header>
      {h?.paths.map((p) => {
        const done = p.sections.filter((s) => s.passed).length;
        const next = p.sections.find((s) => !s.passed);
        return <section key={p.code} className={`fp-paystep${p.passed ? ' is-done' : ''} fp-stack`} data-testid={`path-${p.code}`}>
          <h2 className="fd-section-h">{p.title}</h2>
          <div className="fp-meter"><p className="fp-meter__text"><span>{done} of {p.sections.length} sections passed</span></p>
            <div className="fp-meter__bar" style={{ background: 'var(--fd-hair)' }}><span style={{ width: `${p.sections.length ? Math.round((done / p.sections.length) * 100) : 0}%` }} /></div></div>
          {next ? <Link prefetch={false} className="btn btn--primary fd-wide" href={`/staff/academy/${p.code}/${next.slug}`}>Next: {next.title}</Link>
            : <p className="fp-done"><FdIcon name="check" />All passed</p>}
          <Link prefetch={false} className="link small" href={`/staff/academy/${p.code}`}>All sections of this path</Link>
        </section>;
      })}
      <section className="fd-card stack" aria-labelledby="guide-t"><h2 className="fd-section-h" id="guide-t">The field guide</h2>
        <p className="small">Every screen, step by step: handovers, returns, photos, your shifts and pay.</p>
        <Link prefetch={false} className="btn btn--ghost fd-wide" href="/staff/field/guide">Open the field guide</Link></section>
    </>
  );
}
