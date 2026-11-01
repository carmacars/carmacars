import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { requireInvestor } from '@/server/door';
import { SignList, signCount } from '@/features/manual/SignPages';
import { PortalTabs } from '@/features/portal-nav/PortalTabs';
import { tabOf } from '@/features/portal-nav/tabs';
import { INVESTOR_DOCUMENT_TABS } from '@/features/investor/menu';
import { StatementsTab } from './StatementsTab';
import { FilesTab } from './FilesTab';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Documents', path: '/investor/documents', noindex: true, description: 'Your statements, documents to sign and files.' });

// Documents (r27 portals: Statements, Documents to sign and the file list on Profile were three places for one job).
// /investor/statements and /investor/sign redirect to their tabs; a statement and a document to sign keep their pages.
export default async function InvestorDocuments({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireInvestor('/investor/documents'), searchParams]);
  const tab = tabOf(INVESTOR_DOCUMENT_TABS, sp.tab);
  const toSign = await signCount(user.id).catch(() => 0);
  return (
    <div className="stack">
      <PageHeader title="Documents" />
      <PortalTabs label="Documents" tabs={INVESTOR_DOCUMENT_TABS} current={tab.key} counts={{ sign: toSign }} />
      {tab.key === 'sign' ? <SignList userId={user.id} base="/investor/sign" embedded /> : tab.key === 'files' ? <FilesTab userId={user.id} /> : <StatementsTab userId={user.id} />}
    </div>
  );
}
