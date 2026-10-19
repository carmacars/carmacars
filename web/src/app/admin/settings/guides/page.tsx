import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Badge, Card, PageHead, Table, d } from '@/features/admin/ui';
import { GUIDE_NAME, GUIDE_PATH, type GuidePortal } from '@/server/guides';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Guides', path: '/admin/settings/guides', noindex: true, description: 'The user guide of each portal.' });

type Run = { run: string; sha: string | null; status: string; images: number; sections_rewritten: number; sections_flagged: number; pdfs: number; started_at: string; finished_at: string | null };
type G = { portal: GuidePortal; title: string; version: number; published_at: string | null; published_by_name: string | null; sections: number; unpublished: number;
  readers: number; readers_current: number; auto_updated?: number; auto_updated_at?: string | null; pdf: { generated_at: string; source: string; bytes: number; guide_version: number | null; stale: boolean } | null };

const SOURCE: Record<string, string> = { committed: 'the October 2026 edition', generated: 'printed from the published guide', uploaded: 'uploaded by an Admin' };

// Admin > Settings > Guides (migration 0044): every portal's guide, what is waiting to be published, its PDF and readers.
export default async function Guides() {
  const { user } = await page('/admin/settings/guides');
  const [rows, runs] = await Promise.all([door<G[]>(user.id, 'ops_read', 'guides_admin'), door<Run[]>(user.id, 'ops_read', 'guide_upkeep_runs')]);
  const RUN_STATUS: Record<string, string> = { done: 'finished', failed: 'failed', started: 'running', skipped: 'skipped' };
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="Guides" />
    <p className="small muted">Each portal has a guide, opened from &quot;Guide&quot; at the top of the portal. Edit a guide&apos;s chapters here; readers see your changes once you publish. The PDF people download is the stored one; when the web guide is newer, the guide page says so and offers &quot;Print or save as PDF&quot;.</p>
    <Table<G> testId="guides" rows={rows} rowKey={(r) => r.portal} cols={[
      { key: 'title', label: 'Guide', render: (r) => <Link prefetch={false} className="link" href={`/admin/settings/guides/${r.portal}`} data-testid={`guide-edit-${r.portal}`}>{r.title}</Link> },
      { key: 'version', label: 'Published', render: (r) => r.version ? <>Version {r.version}, {d(r.published_at)}{r.published_by_name ? ` by ${r.published_by_name}` : ''}</> : <Badge s="draft">Not published</Badge> },
      { key: 'auto', label: 'Changed automatically', render: (r) => r.auto_updated_at ? <span data-testid={`guide-auto-${r.portal}`}>Changed automatically on {d(r.auto_updated_at)}{r.auto_updated ? <span className="muted small"> ({r.auto_updated} section{r.auto_updated === 1 ? '' : 's'} you can revert)</span> : null}</span> : <span className="muted">no</span> },
      { key: 'unpublished', label: 'Changes waiting', render: (r) => r.unpublished ? <Badge s="pending_approval">{`${r.unpublished} section${r.unpublished === 1 ? '' : 's'}`}</Badge> : <span className="muted">none</span> },
      { key: 'pdf', label: 'PDF', render: (r) => r.pdf ? <>{d(r.pdf.generated_at)}, {SOURCE[r.pdf.source] ?? r.pdf.source}{r.pdf.stale ? <><br /><span className="small">The web guide has newer edits</span></> : null}</> : <span className="muted">none stored</span> },
      { key: 'readers', label: 'Readers', render: (r) => <>{r.readers}{r.version ? <span className="muted small"> ({r.readers_current} on version {r.version})</span> : null}</> },
      { key: 'view', label: 'Open', render: (r) => <Link prefetch={false} className="link" href={r.portal === 'admin' ? GUIDE_PATH.admin : `/admin/guide/${r.portal}`}>{GUIDE_NAME[r.portal]} guide</Link> }]} />
    <Card title="The guides keep up by themselves" testId="guide-upkeep">
      <p className="small">After every update of the site that changes the portals, the guides are checked automatically: every screenshot is taken again and replaced where the screen changed, and the text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&apos;s own labels and menu and published. Each such section says <b>Changed automatically on</b> and the date, here and in the guide&apos;s editor, with <b>Revert</b> to bring back the text it replaced. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&apos;s history. There is nothing to review. A rewrite that does not pass the checks is asked again more strictly; if it still does not pass, the screenshots and button names are updated, the rest of the text stays, and the next run tries again. The PDFs of the guides that changed are then printed again.</p>
      {runs.length ? <ul className="small" data-testid="guide-upkeep-runs">{runs.map((r) => (
        <li key={r.run}>{d(r.started_at)}: {RUN_STATUS[r.status] ?? r.status}{r.sha ? ` (version ${r.sha.slice(0, 7)})` : ''}: {r.images} screenshot{r.images === 1 ? '' : 's'} replaced, {r.sections_rewritten} section{r.sections_rewritten === 1 ? '' : 's'} rewritten{r.sections_flagged ? `, ${r.sections_flagged} checked again next run` : ''}, {r.pdfs} PDF{r.pdfs === 1 ? '' : 's'} printed</li>))}</ul>
        : <p className="small muted">No automatic run yet. The first one starts after the next update of the site.</p>}
    </Card>
    <Card title="The PDF, printed from the published guide">
      <p className="small">The polished PDF is printed from the published guide by the <b>guides-pdf</b> workflow (GitHub, Actions, guides-pdf, Run workflow), which stores it here with its date. Until then the October 2026 PDFs are offered. You can also store a PDF yourself: open the guide, use &quot;Print or save as PDF&quot;, then upload it on the guide&apos;s page here.</p>
    </Card>
  </>);
}
