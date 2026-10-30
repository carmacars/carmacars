import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';
import { Card, PageHead, Table } from '@/features/admin/ui';
import { InfoTip } from '@/components/InfoTip';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Academy', path: '/admin/academy', noindex: true, description: 'Training progress of every staff member, and the lessons and quizzes.' });

type Staff = { id: string; name: string; email: string; paths: string[]; sections: number; passed: number; last: string | null; done: boolean };
type Content = { paths: Array<{ code: string; title: string; sections: Array<{ id: string; slug: string; title: string; sort: number; lessons: number; scenes: number; questions: number }> }> };
const PATH: Record<string, string> = { cs: 'Customer service', fleet: 'Fleet', finance: 'Finance', sales_in_person: 'Sales in person', sales_remote: 'Sales remote', field: 'Field work', admin: 'Admin' };

// Admin > Academy (Release 21b, item 9): everyone's progress, the paths and their sections to edit, and the Admin's own path.
export default async function AdminAcademy() {
  const { user } = await requireAdmin('/admin/academy');
  const [p, c] = await Promise.all([adminRead<{ staff: Staff[]; gate: boolean }>(user.id, 'academy_progress'), adminRead<Content>(user.id, 'academy_content')]);
  const seen = new Set<string>();
  return (
    <>
      <PageHead title="Academy" kicker="People" purpose="Training paths by staff function: lessons played and narrated in the browser, a quiz per section (pass mark in Settings > Program)."><Link prefetch={false} className="btn btn--sm btn--primary" href="/admin/academy/learn">Take the Admin path</Link></PageHead>
      <p className="small" data-testid="academy-gate">Academy gate: <b>{p.gate ? 'on' : 'off'}</b><InfoTip k="academy_gate" topic="the academy gate" />. Change it in <Link prefetch={false} className="link" href="/admin/settings/program">Settings &gt; Program</Link>.</p>
      <Card title="Progress by staff member">
        <Table<Staff> rows={p.staff} testId="academy-staff" empty="No staff yet." cols={[
          { key: 'name', label: 'Name', render: (r) => <Link prefetch={false} className="link" href={`/admin/academy/staff/${r.id}`}>{r.name}</Link> },
          { key: 'paths', label: 'Paths', render: (r) => r.paths.map((x) => PATH[x] ?? x).join(', ') },
          { key: 'passed', label: 'Sections passed', num: true, render: (r) => `${r.passed} of ${r.sections}` },
          { key: 'done', label: 'Status', render: (r) => (r.done ? 'Passed' : r.passed ? 'In progress' : 'Not started') },
          { key: 'last', label: 'Last quiz', render: (r) => (r.last ? new Date(r.last).toLocaleDateString('en-CA', { timeZone: 'America/Toronto' }) : '') }]} />
      </Card>
      <Card title="Paths and sections">
        <p className="small muted">A section can be on several paths: passed once, it counts on each. Open a section to edit its lessons, scenes and questions.</p>
        {c.paths.map((path) => (
          <div key={path.code} className="stack-s" data-testid={`content-${path.code}`}>
            <h3 className="d5">{path.title}</h3>
            <ol className="small">{path.sections.map((s) => { const first = !seen.has(s.id); seen.add(s.id); return (
              <li key={s.id}><Link prefetch={false} className="link" href={`/admin/academy/sections/${s.id}`}>{s.title}</Link> <span className="muted">· {s.lessons} lessons, {s.scenes} scenes, {s.questions} questions{first ? '' : ' (shared)'}</span></li>); })}</ol>
          </div>
        ))}
      </Card>
    </>
  );
}
