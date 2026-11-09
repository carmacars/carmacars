import { Act } from '@/features/admin/Act';
import type { WelcomeStep } from '@/features/academy/gate';
import { groupsLeft } from './model';

// Step 3 of onboarding (1151): the WhatsApp groups of the person (Sales: the Sales group and the Team group; everyone else the
// Team group), a Join link each when the link is set in Program settings, and one checkbox a group: "I joined". The portal opens
// once every group is ticked (the database checks the academy and the agreement are done first).
export function WhatsAppConfirm({ groups, primary, refresh }: { groups: NonNullable<WelcomeStep['groups']>; primary: boolean; refresh: string }) {
  const left = groupsLeft(groups);
  if (!left.length) return null;
  return (
    <div className="stack" data-testid="welcome-groups">
      <p className="ad-actions">{left.map((g) => g.url
        ? <a key={g.key} className="btn btn--sm btn--primary" href={g.url} target="_blank" rel="noopener noreferrer" data-testid={`welcome-join-${g.key}`}>Join {g.name} on WhatsApp</a>
        : <span key={g.key} className="small" data-testid={`welcome-join-${g.key}`}>{g.name}: ask your manager for the invite link.</span>)}</p>
      <div><Act ops action="staff_whatsapp_confirm" label="I joined" variant={primary ? 'primary' : 'ghost'} title="The WhatsApp groups you joined" submitLabel="Confirm"
        testId="welcome-team-joined" refresh={[refresh]} done="Thanks."
        fields={left.map((g) => ({ name: g.key, label: `I joined ${g.name}`, type: 'bool' as const, value: false }))} /></div>
    </div>
  );
}
