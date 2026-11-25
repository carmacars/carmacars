import { Act } from '@/features/admin/Act';
import type { WelcomeStep } from '@/features/academy/gate';
import { groupsLeft } from './model';
import { MemberTag } from './MemberTag';

// Step 3 of onboarding (1151): the WhatsApp groups of the person (Sales: the Sales group and the Team group; everyone else the
// Team group), a Join link each when the link is set in Program settings, and one checkbox a group: "I joined". The portal opens
// once every group is ticked (the database checks the academy and the agreement are done first).
// r48 FE (3191): next to each group, the person's member tag written for them ("Name - Position") with Copy and the steps;
// "I joined" also needs "I set my member tag". Someone who passed the Sales path without Sales as a role sees the Sales
// group too (not required).
export function WhatsAppConfirm({ groups, primary, refresh }: { groups: NonNullable<WelcomeStep['groups']>; primary: boolean; refresh: string }) {
  const left = groupsLeft(groups);
  if (!left.length) return null;
  const tag = left.find((g) => g.member_tag)?.member_tag;
  return (
    <div className="stack" data-testid="welcome-groups" data-guide="welcome-groups">
      {left.map((g) => (
        <div key={g.key} className="stack" data-testid={`welcome-group-${g.key}`}>
          <p className="ad-actions">{g.url
            ? <a className="btn btn--sm btn--primary" href={g.url} target="_blank" rel="noopener noreferrer" data-testid={`welcome-join-${g.key}`}>Join {g.name} on WhatsApp</a>
            : <span className="small" data-testid={`welcome-join-${g.key}`}>{g.name}: the link is not set yet. Ask your manager for the invite link.</span>}
            {g.required === false && <span className="small muted">You passed the Sales academy: join the Sales group too.</span>}</p>
          {g.member_tag && <MemberTag tag={g.member_tag} testId={`welcome-tag-${g.key}`} />}
        </div>))}
      <div><Act ops action="staff_whatsapp_confirm" label="I joined" variant={primary ? 'primary' : 'ghost'} title="The WhatsApp groups you joined" submitLabel="Confirm"
        testId="welcome-team-joined" refresh={[refresh]} done="Thanks."
        fields={[...left.map((g) => ({ name: g.key, label: `I joined ${g.name}`, type: 'bool' as const, value: false })),
          { name: 'tag_set', label: `I set my member tag${tag ? ` (${tag})` : ''} in each group`, type: 'bool' as const, value: false, required: true }]} /></div>
    </div>
  );
}
