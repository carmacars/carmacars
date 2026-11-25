import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { SelfHealView } from '@/features/self-heal/SelfHealView';
import type { HealStatus } from '@/features/self-heal/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Self-healing', path: '/admin/self-healing', noindex: true, description: 'What the site fixed by itself, what needs you, and the fix library.' });

// Release 50 (4800): Site health > Self-healing. The database's engine (app.job_heal, every minute) matches each problem to the
// fix library, runs the fix, checks it worked and escalates once when it did not. Staff resolve what was escalated and can
// save what fixed it as a new fix.
export default async function SelfHealing() {
  const { user } = await page('/admin/self-healing');
  const s = await door<HealStatus>(user.id, 'admin_read', 'heal_status', { limit: 80 });
  return (<>
    <PageHead title="Self-healing" kicker="Site health"
      purpose="The site finds its own problems, matches each one to the fix library, runs the fix and checks it worked. What it cannot fix safely comes here once, with a To do and a bug report." />
    <SelfHealView s={s} />
  </>);
}
