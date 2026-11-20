import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';
import { MemberTag } from '@/features/staff-onboarding/MemberTag';

// The team's WhatsApp group on the portal home (1064), shown once the academy and the agreement are both done, until the
// person presses I joined. The links are in Program settings (empty until set).
// r48 FE (3191): with the person's member tag to set in each group, and the Sales group for who passed the Sales path.
export async function TeamGroupCard({ userId, aal, refresh }: { userId: string; aal?: 'aal1' | 'aal2' | null; refresh: string }) {
  const groups = await door<Array<{ key: string; name: string; url: string; member_tag?: string }>>(userId, 'ops_read', 'staff_team_groups', {}, aal).catch(() => []);
  if (!groups.length) return null;
  const tag = groups.find((g) => g.member_tag)?.member_tag;
  return (
    <section className="pt-card ad-card stack" data-testid="home-team-groups" aria-label="Team group">
      <p className="small">{groups.some((g) => g.key === 'sales') && groups.length === 1 ? 'You passed the Sales academy: join the Sales group on WhatsApp.' : 'You are all set: join the team on WhatsApp.'}</p>
      <p className="ad-actions">{groups.map((g) => <a key={g.key} className="btn btn--sm btn--primary" href={g.url} target="_blank" rel="noopener noreferrer">Join {g.name}</a>)}</p>
      {tag && <MemberTag tag={tag} testId="home-team-tag" />}
      <p className="ad-actions"><Act ops action="staff_whatsapp_confirm" label="I joined" refresh={[refresh]} done="Thanks." testId="home-team-joined" title="The groups you joined"
        fields={[...groups.map((g) => ({ name: g.key, label: `I joined ${g.name}`, type: 'bool' as const, value: true })),
          { name: 'tag_set', label: `I set my member tag${tag ? ` (${tag})` : ''} in each group`, type: 'bool' as const, value: false, required: true }]} /></p>
    </section>
  );
}
