import { Act } from '@/features/admin/Act';
import { Card, Table, d } from '@/features/admin/ui';
import type { GateRules } from './rules';

// Admin, Settings, Phone number box (migration 0280): one press per box to turn it off (or on), and what it does:
// per day how often a box was shown, a number given, closed without one, and the web booking requests of the day with
// those from visitors who saw a box; the requests a day before the box was first shown and since.
export interface GateDay { day: string; shown: number; given: number; closed: number; texts: number; gallery: number; dates: number; request: number; requests: number; requests_gated: number }
export interface GateReportData {
  rules: GateRules; first_shown: string | null; requests_a_day_before: number | null; requests_a_day_since: number | null;
  totals: { shown: number; given: number; closed: number; verified: number; texts: number }; marketing_opt_ins: number; days: GateDay[];
}

const BOXES: Array<[keyof GateRules & ('gallery' | 'dates' | 'request' | 'verify'), string]> = [
  ['gallery', 'More photos'], ['dates', 'Full availability'], ['request', 'Booking request'], ['verify', 'Code by text']
];
const pct = (a: number, b: number) => (b > 0 ? `${Math.round((a / b) * 100)}%` : '');

export function GateSwitches({ r }: { r: GateRules }) {
  return (
    <div className="ad-tiles" data-testid="gate-switches">
      {BOXES.map(([k, l]) => (
        <div className="ad-tile" key={k}>
          <span className="ad-tile__k">{l}</span>
          <b className="ad-tile__v" data-testid={`gate-state-${k}`}>{r[k] ? 'On' : 'Off'}</b>
          <Act action="phone_gate_switch" payload={{ gate: k, on: !r[k] }} label={r[k] ? 'Turn off' : 'Turn on'} variant={r[k] ? 'ghost' : 'primary'}
            done={`${l}: ${r[k] ? 'off' : 'on'} from now.`} testId={`gate-switch-${k}`} />
        </div>
      ))}
    </div>
  );
}

export function GateReport({ g }: { g: GateReportData }) {
  const t = g.totals;
  return (<>
    <Card title="Last 30 days" testId="gate-report">
      <div className="ad-tiles">
        <div className="ad-tile"><span className="ad-tile__k">Shown</span><b className="ad-tile__v" data-testid="gate-shown">{t.shown}</b><span className="ad-tile__s">times a box opened</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Number given</span><b className="ad-tile__v" data-testid="gate-given">{t.given}</b><span className="ad-tile__s">{pct(t.given, t.shown)} of shown</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Closed</span><b className="ad-tile__v" data-testid="gate-closed">{t.closed}</b><span className="ad-tile__s">without a number</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Also text me deals</span><b className="ad-tile__v">{g.marketing_opt_ins}</b><span className="ad-tile__s">ticked</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Codes texted</span><b className="ad-tile__v">{t.texts}</b><span className="ad-tile__s">about ${(t.texts / 100).toFixed(2)}</span></div>
      </div>
      <p className="small" data-testid="gate-before-after">{g.first_shown
        ? <>Web booking requests a day: <b className="num">{g.requests_a_day_before ?? 0}</b> in the 28 days before the box was first shown ({d(g.first_shown)}), <b className="num">{g.requests_a_day_since ?? 0}</b> since. Other things change too (season, prices, ads): read it with the days below.</>
        : 'The box has not been shown yet.'}</p>
    </Card>
    <Card title="By day">
      <Table rows={g.days as unknown as Record<string, unknown>[]} testId="gate-days" empty="Nothing yet." cols={[
        { key: 'day', label: 'Day', render: (r) => d(r.day) },
        { key: 'shown', label: 'Shown', num: true, render: (r) => String(r.shown) },
        { key: 'given', label: 'Number given', num: true, render: (r) => String(r.given) },
        { key: 'closed', label: 'Closed', num: true, render: (r) => String(r.closed) },
        { key: 'gallery', label: 'Photos / availability / request', render: (r) => `${r.gallery} / ${r.dates} / ${r.request}` },
        { key: 'requests', label: 'Web requests', num: true, render: (r) => String(r.requests) },
        { key: 'requests_gated', label: 'From visitors who saw a box', num: true, render: (r) => String(r.requests_gated) }
      ]} />
    </Card>
  </>);
}
