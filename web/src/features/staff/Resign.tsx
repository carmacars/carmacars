import { door } from '@/server/door';
import { ResignForm } from './ResignForm';
import type { ResignFacts } from './resign';

// r50 (5020): the Resign section, last on My profile (away from the daily buttons) and on Welcome while in onboarding.
export async function ResignSection({ userId, portal, className, refresh }: { userId: string; portal: 'va' | 'field'; className: string; refresh: string[] }) {
  const f = await door<ResignFacts>(userId, portal === 'field' ? 'field_read' : 'ops_read', 'staff_resign_facts', {}).catch(() => null);
  if (!f?.staff || !f.active) return null;
  return (
    <section className={className} aria-labelledby="resign-t" id="resign" data-testid="profile-resign"><h2 className="d4" id="resign-t">Resign</h2>
      <ResignForm facts={f} refresh={refresh} />
    </section>
  );
}
