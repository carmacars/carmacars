import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { tabOf } from '@/features/admin/hubs';
import { Emails } from './Emails';
import { Audit } from './Audit';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Logs', path: '/admin/logs', noindex: true, description: 'Emails sent, blocked addresses, every change and every look at personal data.' });

const TABS = ['emails', 'blocked', 'changes', 'access'] as const;

// Settings > Logs (r27, the owner on November 1, 2026: "We need less pages not more"): the email log and the audit log on
// one page, four tabs. /admin/messages and /admin/audit redirect to their tabs.
export default async function Logs({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([page('/admin/logs'), searchParams]);
  const tab = tabOf(TABS, sp.tab);
  if (tab === 'changes' || tab === 'access') return <Audit ctx={ctx} sp={sp} tab={tab} />;
  return <Emails ctx={ctx} sp={sp} tab={tab} />;
}
