import '@/styles/investor-model.css';
import { pageMeta } from '@/features/seo/meta';
import { requireInvestor } from '@/server/door';
import { loadInvestorModel } from '@/server/investor-model';
import { InvestorModelView, TABS, type Tab } from '@/features/investor-model/View';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your investment sheets', path: '/investor/model', noindex: true, description: 'Your investment, live from your records, with the calculators.' });

// The investor's sheets (the owner's request of November 1, 2026: the model spreadsheets "live and auto updating on the
// investor portal, downloadable"). One page with four tabs: their own investment from their records (it updates itself as
// payouts are recorded), the calculator, how it works, and the fund-a-car calculator; Excel and PDF downloads of the same.
// Only the investor's own numbers and the investment terms are read here: never the fleet, its use, its insurance or costs.
export default async function InvestorModel({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { user } = await requireInvestor('/investor/model');
  const tab: Tab = (TABS.find(([k]) => k === sp.tab)?.[0] ?? 'mine');
  const reinvest = sp.reinvest === '1' ? true : sp.reinvest === '0' ? false : undefined;
  const m = await loadInvestorModel(user.id, reinvest);
  return <InvestorModelView m={m} tab={tab} reinvest={reinvest} />;
}
