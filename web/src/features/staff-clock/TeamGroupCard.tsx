import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';

// The team's WhatsApp group on the portal home (1064), shown once the academy and the agreement are both done, until the
// person presses I joined. The links are in Program settings (empty until set).
export async function TeamGroupCard({ userId, aal, refresh }: { userId: string; aal?: 'aal1' | 'aal2' | null; refresh: string }) {
  const groups = await door<Array<{ key: string; name: string; url: string }>>(userId, 'ops_read', 'staff_team_groups', {}, aal).catch(() => []);
  if (!groups.length) return null;
  return (
    <section className="pt-card ad-card stack" data-testid="home-team-groups" aria-label="Team group">
      <p className="small">You are all set: join the team on WhatsApp.</p>
      <p className="ad-actions">{groups.map((g) => <a key={g.key} className="btn btn--sm btn--primary" href={g.url} target="_blank" rel="noopener noreferrer">Join {g.name}</a>)}
        <Act ops action="staff_team_joined" label="I joined" refresh={[refresh]} done="Thanks." testId="home-team-joined" /></p>
    </section>
  );
}
