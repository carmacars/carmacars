import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';
import { Rubric } from '@/features/careers/admin/Rubric';
import { Hire } from '@/features/careers/admin/Hire';
import { fmtSlot, MANILA, SOURCE_WORDS, STATUS_WORDS, type Criterion } from '@/features/careers/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Candidate', path: '/admin/hiring', noindex: true, description: 'One application: the answers and the score, the call, the rubric beside the call guide, and the decision.' });
type R = Record<string, unknown>;
interface Detail {
  application: { id: string; role: string; role_slug: string; status: string; full_name: string; email: string | null; phone: string | null; profile_name: string | null; source: string;
    utm: Record<string, string>; score: number | null; score_points: number | null; score_max: number | null; pass_mark: number; knockouts: string[]; ko_reasons: string[]; created_at: string;
    slot_starts_at: string | null; mode: string | null; meet_url: string | null; booking_url: string; final_score: number | null; interview_score: number | null; rank: number | null;
    referred_role: string | null; referred_from: string | null; referral_application: string | null; note: string | null; hired_user_id: string | null; purged: boolean };
  role: { slug: string; title: string; short_title: string; staff_kind: string; va_function: string | null; remote: boolean; test_task: string | null;
    call_guide: { steps?: Array<[string, string]>; questions?: Array<[string, string]> } };
  breakdown: Array<{ key: string; label: string; answer: string | null; points: number; max: number }>;
  criteria: Criterion[];
  score: { scores: Record<string, number>; interview_score: number | null; final_score: number | null; notes: string | null; decision: string | null; interviewer: string | null; updated_at: string } | null;
  linked: Array<{ id: string; role: string; status: string; score: number | null; created_at: string; referred_from: string | null }>;
  phone_enabled: boolean;
}

// One candidate (migration 0173): contact, source, the answers with the points each earned, the knock-outs, the booked call,
// the rubric beside the call guide, the linked applications (a referral to another role, both ways), the decisions and Hire.
export default async function Candidate({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { read } = await page(`/admin/hiring/${id}`);
  const x = await read<Detail>('hiring_application', { id });
  const a = x.application;
  const base = '/admin/hiring';
  const refresh = [base, `${base}/${id}`];
  const tel = a.phone ? a.phone.replace(/[^\d+]/g, '') : null;
  const portal = x.role.staff_kind === 'field' ? 'field staff' : 'assistant';
  const canScore = ['booked', 'interviewed', 'invited', 'no_show'].includes(a.status);
  return (<>
    <PageHead title={a.full_name} kicker={<><Link prefetch={false} className="link" href={base}>Hiring</Link> · {x.role.title}</>}
      purpose={<span data-testid="cand-status"><Badge s={['hired', 'interviewed', 'booked'].includes(a.status) ? 'published' : 'draft'}>{STATUS_WORDS[a.status] ?? a.status}</Badge>
        {a.status === 'referred' && a.referred_role ? ` to ${a.referred_role}` : ''}{a.rank ? ` · Rank ${a.rank} in ${x.role.short_title}` : ''}</span>}>
      <span className="ad-actions">
        {['below_bar', 'declined', 'referred', 'no_show'].includes(a.status) && <Act action="hiring_invite" payload={{ id }} label="Invite anyway" variant="primary" testId="cand-invite" refresh={refresh} done="Invited: the booking link is on its way." confirm={`Send ${a.full_name} the booking link?`} />}
        {['below_bar', 'invited', 'referred', 'no_show'].includes(a.status) && <Act action="hiring_decline" payload={{ id }} label="Decline" testId="cand-decline" refresh={refresh} done="Declined."
          fields={[{ name: 'email', label: 'Send the polite decline email', type: 'bool', value: true }, { name: 'reason', label: 'The requirement it names (optional: "This role needs ...")', type: 'text' }]} />}
        {a.status === 'booked' && <Act action="hiring_no_show" payload={{ id }} label="No show" testId="cand-noshow" refresh={refresh} done="Marked as a no-show." confirm="Mark this call as a no-show?" />}
        {['interviewed', 'no_show', 'booked'].includes(a.status) && <Act action="hiring_reject" payload={{ id }} label="Not hired" testId="cand-reject" refresh={refresh} done="Marked as not hired. No email is sent." confirm="Mark as not hired? No email is sent." />}
        {!['hired', 'withdrawn'].includes(a.status) && !a.purged && <Act action="hiring_withdraw" payload={{ id }} label="Withdrawn" testId="cand-withdraw" refresh={refresh} done="Marked as withdrawn." confirm="Mark as withdrawn (they no longer want the role)?" />}
      </span>
    </PageHead>
    <div className="ad-grid ad-grid--2">
      <div className="stack-lg">
        <Card title="Contact and source" testId="cand-contact">
          <Kv rows={[
            ['Email', a.email ? <a className="link" href={`mailto:${a.email}`}>{a.email}</a> : 'Removed'],
            ['Phone', tel ? <a className="link" href={`tel:${tel}`} data-testid="cand-call">{x.phone_enabled ? 'Call (Quo) ' : 'Call '}{a.phone}</a> : '-'],
            ['Profile name', a.profile_name ?? '-'], ['Source', SOURCE_WORDS[a.source] ?? a.source],
            ['Campaign', Object.entries(a.utm ?? {}).map(([k, v]) => `${k.replace('utm_', '')}: ${v}`).join(', ') || '-'], ['Applied', t(a.created_at)],
            ['Booking link', <a key="b" className="link" href={a.booking_url} rel="noopener" target="_blank">Open the candidate&apos;s booking page</a>]]} />
        </Card>
        <Card title={`Call${a.slot_starts_at ? `: ${fmtSlot(a.slot_starts_at)}` : ''}`} testId="cand-call-card">
          {a.slot_starts_at
            ? <p>{x.role.remote && <span className="small muted">{fmtSlot(a.slot_starts_at, MANILA)} in Manila. </span>}
                {a.mode === 'video' ? (a.meet_url ? <a className="btn btn--ghost btn--sm" href={a.meet_url} rel="noopener" target="_blank">Join the video call</a> : 'Video')
                  : tel ? <a className="btn btn--ghost btn--sm" href={`tel:${tel}`}>Call {a.phone}</a> : 'Phone'}</p>
            : <p className="muted small">No call booked{a.status === 'invited' ? ': the candidate has the booking link.' : '.'}</p>}
        </Card>
        <Card title={`Screening: ${a.score ?? '-'} of 100${a.score !== null ? (a.score >= a.pass_mark ? ' (passed)' : ` (pass mark ${a.pass_mark})`) : ''}`} testId="cand-breakdown">
          {a.knockouts.length > 0 && <p className="alert alert--error"><span><b>Knock-out:</b> {a.knockouts.join('; ')}</span></p>}
          <Table<R> rows={x.breakdown as unknown as R[]} rowKey={(r) => String(r.key)} cols={[
            { key: 'label', label: 'Question', className: 'wrap' }, { key: 'answer', label: 'Answer', className: 'wrap', render: (r) => String(r.answer ?? (a.purged ? 'Removed' : '-')) },
            { key: 'points', label: 'Points', num: true, render: (r) => (Number(r.max) > 0 ? `${String(r.points)} / ${String(r.max)}` : '') }]} />
          {a.score_points !== null && <p className="small muted">{a.score_points} of {a.score_max} points.</p>}
        </Card>
        {x.linked.length > 0 && <Card title="Linked applications" testId="cand-linked">
          <Table<R> rows={x.linked as unknown as R[]} rowKey={(r) => String(r.id)} cols={[
            { key: 'role', label: 'Role', render: (r) => <Link prefetch={false} className="link" href={`${base}/${String(r.id)}`}>{String(r.role)}</Link> },
            { key: 'how', label: 'Link', render: (r) => (r.id === a.referred_from ? 'Referred from this application' : r.referred_from === a.id ? 'Applied after our referral' : 'Same email') },
            { key: 'status', label: 'Status', render: (r) => STATUS_WORDS[String(r.status)] ?? String(r.status) }, { key: 'score', label: 'Score', num: true }, { key: 'created_at', label: 'Applied', render: (r) => d(r.created_at) }]} />
        </Card>}
        <Card title="Note (only Admins see it)" testId="cand-note">
          {a.note && <p className="small" style={{ whiteSpace: 'pre-wrap' }}>{a.note}</p>}
          <Act action="hiring_note" payload={{ id }} label={a.note ? 'Change the note' : 'Add a note'} refresh={refresh} done="Saved." fields={[{ name: 'note', label: 'Note', type: 'textarea', value: a.note ?? '' }]} />
        </Card>
      </div>
      <div className="stack-lg" id="rubric">
        <Card title="Interview rubric" testId="cand-rubric" aside={x.score?.updated_at ? <span className="small muted">Saved {t(x.score.updated_at)}{x.score.interviewer ? ` by ${x.score.interviewer}` : ''}</span> : undefined}>
          {canScore || x.score
            ? <Rubric id={id} criteria={x.criteria} screening={a.score} initial={x.score ? { scores: x.score.scores, notes: x.score.notes, decision: x.score.decision } : null} />
            : <p className="muted small">The rubric opens once the candidate has a call.</p>}
        </Card>
        <Card title="Call guide (15 minutes)" testId="cand-guide">
          <ol className="cr-guide">{(x.role.call_guide.steps ?? []).map(([time, text]) => <li key={time}><b>{time}</b> {text}</li>)}</ol>
          <h3 className="d4">{x.role.short_title}: role questions</h3>
          <ul className="cr-guide">{(x.role.call_guide.questions ?? []).map(([q, good]) => <li key={q}>{q} <span className="muted small">Good: {good}</span></li>)}</ul>
          {x.role.test_task && <p className="small"><b>The paid test:</b> {x.role.test_task}</p>}
        </Card>
        {['interviewed', 'hired'].includes(a.status) && <Card title="Decision" testId="cand-hire">
          <Hire id={id} name={a.full_name} portal={portal} hiredUserId={a.hired_user_id} />
        </Card>}
      </div>
    </div>
  </>);
}
