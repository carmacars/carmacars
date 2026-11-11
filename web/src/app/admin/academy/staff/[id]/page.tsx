import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';
import { Card, PageHead, Table } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { pct, type PathRow, type SectionRow } from '@/features/academy/model';
import { AcademyGateCard } from '@/features/academy/GateCard';
import type { GateState } from '@/features/academy/gate';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Academy progress', path: '/admin/academy', noindex: true, description: 'One staff member\'s training progress.' });

// One staff member's progress (Release 21b, item 9): each path's sections, scores and attempts; open a section early.
// 1154: attempts answered too fast are counted, and an Admin resets chosen sections.
export default async function AcademyPerson({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await requireAdmin(`/admin/academy/staff/${id}`);
  const p = await adminRead<{ user: { id: string; name: string; email: string } | null; paths: PathRow[]; attempts: Array<{ section: string; score_bps: number; passed: boolean; at: string }> }>(user.id, 'academy_progress', { user_id: id });
  if (!p.user) notFound();
  const here = `/admin/academy/staff/${id}`;
  // 0802: held or open, and the waiver
  const gate = await adminRead<GateState>(user.id, 'academy_gate_state', { user_id: id }).catch(() => null);
  return (
    <>
      <PageHead title={p.user.name} kicker="Academy" purpose={p.user.email}><Link prefetch={false} className="btn btn--sm btn--quiet" href="/admin/academy">All staff</Link></PageHead>
      {gate && gate.sections > 0 && <AcademyGateCard g={gate} refresh={[here]} />}
      {!p.paths.length && <p className="muted">No path: give this person a staff function in Settings &gt; Staff.</p>}
      {p.paths.map((path) => (
        <Card key={path.code} title={`${path.title}${path.passed ? ' (passed)' : ''}`}>
          {/* 1154: the chosen sections start over for this person (passes, lessons watched, reading clock); the attempts stay on record; logged */}
          <div><Act action="academy_reset" payload={{ user_id: id }} label="Reset sections" title={`Reset sections for ${p.user!.name}`} submitLabel="Reset" refresh={[here]} done="Reset."
            fields={path.sections.map((r) => ({ name: `s_${r.id}`, label: `${r.title}${r.passed ? ' (passed)' : ''}`, type: 'bool' as const, value: false }))} testId={`reset-${path.code}`} /></div>
          <Table<SectionRow & Record<string, unknown>> rows={path.sections as Array<SectionRow & Record<string, unknown>>} testId={`ap-${path.code}`} cols={[
            { key: 'title', label: 'Section' },
            { key: 'viewed', label: 'Lessons watched', num: true, render: (r) => `${r.viewed} of ${r.lessons}` },
            { key: 'best', label: 'Best score', num: true, render: (r) => pct(r.best_bps) },
            { key: 'attempts', label: 'Attempts', num: true },
            { key: 'flagged', label: 'Too fast', num: true, render: (r) => (r.flagged ? `${r.flagged} flagged` : '') },
            { key: 'state', label: 'State', render: (r) => (r.passed ? 'Passed' : r.open ? (r.unlocked_early ? 'Opened early' : 'Open') : 'Closed') },
            { key: 'act', label: '', render: (r) => (!r.open && !r.passed ? <Act action="academy_unlock" payload={{ user_id: id, section: r.id }} label="Open early" testId={`unlock-${r.slug}`} refresh={[here]}
                fields={[{ name: 'reason', label: 'Reason', required: true, placeholder: 'For example: experienced in this work' }]} done="Opened." /> : null) }]} />
        </Card>
      ))}
      <Card title="Quiz attempts">
        <Table rows={p.attempts} testId="ap-attempts" empty="No quiz yet." cols={[{ key: 'section', label: 'Section' }, { key: 'score_bps', label: 'Score', num: true, render: (r) => pct(r.score_bps as number) },
          { key: 'passed', label: 'Result', render: (r) => (r.passed ? 'Passed' : 'Not passed') }, { key: 'at', label: 'When', render: (r) => new Date(String(r.at)).toLocaleString('en-CA', { timeZone: 'America/Toronto' }) }]} />
      </Card>
    </>
  );
}
