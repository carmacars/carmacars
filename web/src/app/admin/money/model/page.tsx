import '@/components/portal-ui/portal-ui.css';
import '@/styles/investor-model.css';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { loadFinanceModel } from '@/server/finance-model';
import { Act } from '@/features/admin/Act';
import { CompanyModelView } from '@/features/finance-model/View';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Company model', path: '/admin/money/model', noindex: true, description: 'Actuals, the forecast and the pro forma, live from the database.' });
const base = '/admin/money/model';

// Admin > Money > Company model (the owner's request of November 1, 2026; migration 0420): the model workbook's internal
// tabs as one page. Actuals fill themselves each hour from the database (the summary table, not on each view); the forecast
// and the pro forma run from the latest complete actual month and the assumptions saved here; the Excel download is the
// full internal workbook with live formulas. Admins only (the database refuses anyone else, Finance included).
export default async function CompanyModel({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireAdmin(base), searchParams]);
  const { read, inputs, model } = await loadFinanceModel(user.id);
  return <CompanyModelView read={read} inputs={inputs} model={model} tab={sp.tab} actions={<>
    <a className="btn btn--primary btn--sm" href={`${base}/excel`} data-testid="model-admin-excel" download>Download as Excel</a>
    <Act action="finance_model_refresh" label="Refresh actuals now" testId="model-refresh" refresh={[base]} done="Actuals refreshed." />
  </>} />;
}
