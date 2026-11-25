import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Card, Kv, PageHead } from '@/features/admin/ui';
import { Rubric } from '@/features/careers/admin/Rubric';
import { fmtSlot, STATUS_WORDS, type Criterion } from '@/features/careers/model';
import { CallRoom } from '@/features/calls/CallRoom';
import { mediaConfig } from '@/server/calls';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Interview call', path: '/admin/hiring', noindex: true, description: 'The candidate\'s interview call in the site, with their details, the rubric and the outcome beside the video.' });

interface Detail {
  application: { id: string; status: string; full_name: string; email: string | null; phone: string | null; score: number | null; pass_mark: number; slot_starts_at: string | null; mode: string | null; meet_url: string | null; location?: string | null };
  role: { title: string; short_title: string; call_guide: { steps?: Array<[string, string]>; questions?: Array<[string, string]> } };
  breakdown: Array<{ key: string; label: string; answer: string | null }>;
  criteria: Criterion[];
  score: { scores: Record<string, number>; notes: string | null; decision: string | null } | null;
}

// r50 (5010): the interviewer's side of an interview call: the private room of the slot (the candidate joins from the
// link in their email, no account), the candidate's details and the role's questions beside the video, the rubric and
// the outcome buttons of the candidate's page.
export default async function InterviewCall({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { read } = await page(`/admin/hiring/${id}/call`);
  const x = await read<Detail>('hiring_application', { id });
  const a = x.application;
  const base = `/admin/hiring/${id}`;
  const refresh = [base, `${base}/call`];
  const inSite = mediaConfig().provider !== 'off' && !!a.meet_url?.includes('/call/i/');
  const side = (<div className="stack" data-testid="iv-candidate" data-guide="iv-candidate">
    <Kv rows={[['Status', STATUS_WORDS[a.status] ?? a.status], ['Call', a.slot_starts_at ? fmtSlot(a.slot_starts_at) : '-'], ['Email', a.email ?? '-'], ['Phone', a.phone ?? '-'], ['Lives in', a.location ?? '-'],
      ['Screening', a.score === null ? '-' : `${a.score} of 100${a.score >= a.pass_mark ? ' (passed)' : ''}`]]} />
    {!!x.breakdown.length && <details><summary className="link small">Their answers</summary>
      <ul className="small">{x.breakdown.filter((b) => b.answer).map((b) => <li key={b.key}><b>{b.label}</b>: {b.answer}</li>)}</ul></details>}
    {!!x.role.call_guide.questions?.length && <><h3 className="d4">{x.role.short_title}: questions</h3>
      <ul className="small">{x.role.call_guide.questions.map(([q, good]) => <li key={q}>{q} <span className="muted">Good: {good}</span></li>)}</ul></>}
    <h3 className="d4">Rubric</h3>
    <Rubric id={id} criteria={x.criteria} screening={a.score} initial={x.score ? { scores: x.score.scores, notes: x.score.notes, decision: x.score.decision } : null} />
    <div className="row" data-guide="iv-outcome">
      {a.status === 'booked' && <Act action="hiring_no_show" payload={{ id }} label="No show" testId="iv-noshow" refresh={refresh} done="Marked as a no-show." confirm="Mark this call as a no-show?" />}
      {['interviewed', 'no_show', 'booked'].includes(a.status) && <Act action="hiring_reject" payload={{ id }} label="Not hired" testId="iv-reject" refresh={refresh} done="Marked as not hired. No email is sent." confirm="Mark as not hired? No email is sent." />}
      <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}#rubric`}>Hire and the decision email</Link>
    </div>
  </div>);
  return (<>
    <PageHead title={`Interview: ${a.full_name}`} kicker={<><Link prefetch={false} className="link" href="/admin/hiring">Hiring</Link> · <Link prefetch={false} className="link" href={base}>{a.full_name}</Link> · {x.role.title}</>}
      purpose="The candidate joins from the link in their email. Their details and the rubric are beside the video." />
    {a.mode !== 'video' || !a.slot_starts_at
      ? <Card title="No video call" testId="iv-none"><p className="small">This candidate has no video call booked.</p></Card>
      : inSite
        ? <CallRoom join={{ as: { room: 'interview', application_id: id } }} title={`Interview call with ${a.full_name}`} side={side} sideTitle="Candidate" leaveHref={base} />
        : <Card title="The call is on the outside link" testId="iv-outside">
            {a.meet_url && !a.meet_url.includes('/call/i/') ? <a className="btn btn--primary btn--sm" href={a.meet_url} target="_blank" rel="noopener noreferrer">Join the video call</a>
              : <p className="small">The call in the site is not available right now. Call the candidate on their phone, or email them another link.</p>}
            {side}
          </Card>}
  </>);
}
