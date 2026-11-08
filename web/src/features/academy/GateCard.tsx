import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { gateWords, type GateState } from './gate';

// The academy gate of one staff member (0802), for Admin: held or open, the sections passed, and Waive (with a reason) or
// Take the waiver back. On the person's academy page and on the hiring card of a hire.
export function AcademyGateCard({ g, refresh, link = false }: { g: GateState; refresh: string[]; link?: boolean }) {
  return (
    <Card title="Academy gate" testId="academy-gate-card">
      <p className="small" data-testid="academy-gate-state">{gateWords(g)}</p>
      {link && <p className="small"><Link prefetch={false} className="link" href={`/admin/academy/staff/${g.user_id}`}>Academy progress</Link></p>}
      {g.waiver
        ? <Act action="academy_waive" payload={{ user_id: g.user_id, on: false }} label="Take the waiver back" testId="academy-unwaive" refresh={refresh} done="The gate holds them again until they pass." confirm="Hold them again until they pass the academy?" />
        : !g.done && <Act action="academy_waive" payload={{ user_id: g.user_id, on: true }} label="Waive the academy" testId="academy-waive" refresh={refresh} done="Waived: their portal is open."
            fields={[{ name: 'reason', label: 'Reason (kept in the audit log)', required: true, placeholder: 'For example: years of the same work elsewhere' }]} />}
    </Card>
  );
}
