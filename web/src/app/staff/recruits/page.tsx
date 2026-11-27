import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { CopyLink } from '@/features/staff-recruits/CopyLink';
import { Badge, Card, d, PageHead, Table, Tiles } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My recruits', path: '/staff/recruits', noindex: true, description: 'Your invite link for people who could join the sales team, and where each one is.' });

type Row = { id: string; name: string; role: string; applied_at: string; status: string; words: string; hired: boolean };
type Data = { code: string | null; link: string | null; can_invite: boolean; rows: Row[] };

// 5135: an in-person salesperson's invite link. The person applies from it and does the interview like every candidate;
// they are tracked here under the salesperson who invited them.
export default async function MyRecruits() {
  const { read } = await vaPage('/staff/recruits', ['sales']);
  const x = await read<Data>('my_recruits');
  return (<>
    <PageHead title="My recruits" purpose="Know someone who would sell well in person? Send them your invite link. They apply and do the interview like every candidate, and they show here under your name." />
    <Tiles items={[{ k: 'Invited and applied', v: x.rows.length }, { k: 'Hired', v: x.rows.filter((r) => r.hired).length }]} />
    <Card title="Your invite link" testId="recruit-link">
      {x.link ? <CopyLink link={x.link} />
        : x.can_invite ? <Act action="recruit_link" label="Make my invite link" variant="primary" refresh={['/staff/recruits']} done="Your link is ready." testId="recruit-link-make" />
        : <p className="small muted">Invite links are for in-person salespeople.</p>}
    </Card>
    <Card title="People you invited" testId="recruit-list">
      <Table<Row> rows={x.rows} rowKey={(r) => r.id} empty="Nobody has applied from your link yet. Share it with someone who could join the team." cols={[
        { key: 'name', label: 'Name' }, { key: 'role', label: 'Role' }, { key: 'applied_at', label: 'Applied', render: (r) => d(r.applied_at) },
        { key: 'words', label: 'Where they are', render: (r) => <Badge s={r.hired ? 'paid' : 'pending'}>{r.words}</Badge> }]} />
    </Card>
  </>);
}
