import { Act, SaveForm } from '@/features/admin/Act';
import { fieldsFrom } from '@/features/admin/fields';
import { Card, Table } from '@/features/admin/ui';
import { kmText } from './model';

type R = Record<string, unknown>;
export interface MaintSettings {
  items: Array<R & { code: string; label: string; kind: string; interval_km: number | null; interval_months: number | null; due_soon_km: number | null; due_soon_days: number | null;
    block_bookings_when_overdue: boolean; block_handover_when_expired: boolean; active: boolean; help: string | null }>;
  rules: Array<R & { id: string; item_code: string; vehicle_class: string | null; vehicle_id: string | null; vehicle_name: string | null }>;
  categories: Array<{ code: string; label: string; item_codes: string[] | null; is_service: boolean }>;
  classes: string[]; vehicles: Array<{ id: string; name: string }>;
}
const KIND: Record<string, string> = { interval: 'By km and months', record: 'Recorded when done', expiry: 'Expiry date', tires: 'Tread and age', seasonal: 'Seasonal dates' };
const MAINT_KEYS = ['maint_due_soon_km', 'maint_due_soon_days', 'maint_default_km_per_day', 'maint_km_per_day_window_days', 'maint_winter_on_reminder', 'maint_winter_on_by',
  'maint_winter_off_from', 'maint_winter_off_by', 'maint_tire_replace_mm', 'maint_tire_soon_mm', 'maint_tasks_enabled', 'maint_digest_enabled', 'maint_winter_addon_link'];
const R_ = ['/admin/settings/maintenance', '/admin/maintenance'];

// Admin > Settings > Maintenance (migration 0089): each item's default interval, due-soon thresholds and blocks; the
// intervals by class and by car; which expense categories are a service; the reminder settings (Program settings).
export function MaintenanceSettings({ s, program }: { s: MaintSettings; program: R }) {
  const label = (code: string) => s.items.find((i) => i.code === code)?.label ?? code;
  return (<>
    <Card title="Service items and their intervals" testId="maint-settings-items">
      <p className="small muted">Whichever of km and months comes first is due. An empty or 0 interval means not by that measure. Due soon: empty follows the reminder settings below (1,000 km or 14 days). A change applies to every car at once.</p>
      <Table rows={s.items} rowKey={(r) => r.code} caption="Service items" cols={[
        { key: 'label', label: 'Item', render: (r) => <span><b>{r.label}</b>{!r.active ? <span className="small muted"> (off)</span> : null}<br /><span className="small muted">{KIND[r.kind]}</span></span> },
        { key: 'interval', label: 'Every', render: (r) => [r.interval_km ? kmText(r.interval_km) : '', r.interval_months ? `${r.interval_months} months` : ''].filter(Boolean).join(' or ') || <span className="muted">none</span> },
        { key: 'soon', label: 'Due soon', render: (r) => [r.due_soon_km !== null ? kmText(r.due_soon_km) : '', r.due_soon_days !== null ? `${r.due_soon_days} days` : ''].filter(Boolean).join(' or ') || <span className="muted">default</span> },
        { key: 'blocks', label: 'Blocks', className: 'wrap', render: (r) => [r.block_handover_when_expired ? 'Handover when expired' : '', r.block_bookings_when_overdue ? 'New bookings when overdue' : ''].filter(Boolean).join(', ') || <span className="muted">nothing</span> },
        { key: 'act', label: '', render: (r) => <Act ops action="maint_item_save" payload={{ code: r.code }} label="Change" title={r.label} refresh={R_} testId={`item-${r.code}`} done="Saved." fields={[
          { name: 'label', label: 'Name', value: r.label, required: true },
          ...(['interval', 'record', 'expiry', 'tires'].includes(r.kind) ? [{ name: 'interval_km', label: 'Every (km)', type: 'number' as const, value: r.interval_km, min: 0 }] : []),
          ...(r.kind !== 'seasonal' ? [{ name: 'interval_months', label: r.kind === 'tires' ? 'Replace at this age (months)' : 'Every (months)', type: 'number' as const, value: r.interval_months, min: 0 }] : []),
          { name: 'due_soon_km', label: 'Due soon, km before (empty: the default)', type: 'number', value: r.due_soon_km, min: 0 },
          { name: 'due_soon_days', label: 'Due soon, days before (empty: the default)', type: 'number', value: r.due_soon_days, min: 0 },
          { name: 'block_bookings_when_overdue', label: 'Block new bookings on a car while this is overdue', type: 'bool', value: r.block_bookings_when_overdue },
          ...(r.kind === 'expiry' ? [{ name: 'block_handover_when_expired', label: 'Refuse the handover once it has expired', type: 'bool' as const, value: r.block_handover_when_expired }] : []),
          { name: 'active', label: 'Tracked', type: 'bool', value: r.active }]} /> }]} />
    </Card>
    <Card title="Intervals by class or for one car" testId="maint-settings-rules" aside={<Act ops action="maint_rule_save" payload={{}} label="Add an interval" refresh={R_} testId="rule-add" done="Saved." fields={[
      { name: 'item_code', label: 'Item', type: 'select', required: true, options: s.items.map((i) => [i.code, i.label] as [string, string]) },
      { name: 'vehicle_class', label: 'Class (or choose a car)', type: 'select', options: s.classes.map((c) => [c, c.charAt(0).toUpperCase() + c.slice(1)] as [string, string]) },
      { name: 'vehicle_id', label: 'Car', type: 'select', options: s.vehicles.map((v) => [v.id, v.name] as [string, string]) },
      { name: 'interval_km', label: 'Every (km; 0: not by km)', type: 'number', min: 0 }, { name: 'interval_months', label: 'Every (months; 0: not by date)', type: 'number', min: 0 },
      { name: 'due_soon_km', label: 'Due soon (km before)', type: 'number', min: 0 }, { name: 'due_soon_days', label: 'Due soon (days before)', type: 'number', min: 0 },
      { name: 'active', label: 'Tracked', type: 'select', options: [['true', 'Yes'], ['false', 'No']] },
      { name: 'block_bookings_when_overdue', label: 'Block new bookings when overdue', type: 'select', options: [['true', 'Yes'], ['false', 'No']] }]} />}>
      <p className="small muted">A car&apos;s own interval comes first, then its class&apos;s (the deposit class on the car), then the default above. Empty fields follow the next level.</p>
      <Table rows={s.rules} rowKey={(r) => r.id} empty="No interval by class or car: every car follows the defaults." caption="Intervals by class or car" cols={[
        { key: 'item_code', label: 'Item', render: (r) => label(r.item_code) },
        { key: 'for', label: 'For', render: (r) => r.vehicle_name ?? `Class: ${String(r.vehicle_class)}` },
        { key: 'interval', label: 'Every', render: (r) => [r.interval_km !== null ? (Number(r.interval_km) ? kmText(Number(r.interval_km)) : 'not by km') : '', r.interval_months !== null ? (Number(r.interval_months) ? `${String(r.interval_months)} months` : 'not by date') : ''].filter(Boolean).join(', ') || 'as the default' },
        { key: 'active', label: 'Tracked', render: (r) => r.active === false ? 'No' : r.active === true ? 'Yes' : 'as the default' },
        { key: 'act', label: '', render: (r) => <Act ops action="maint_rule_delete" payload={{ id: r.id }} label="Remove" variant="quiet" refresh={R_} confirm="The cars go back to the next level's interval." /> }]} />
    </Card>
    <Card title="Expense categories that are a service" testId="maint-settings-categories">
      <p className="small muted">An expense entered under Money, Expenses with a car and one of these categories records a service of its items on that car (the timers reset). A service recorded under Maintenance and paid by CarmaCars is entered under the category whose items match.</p>
      <Table rows={s.categories.filter((c) => c.is_service || c.code.startsWith('repair'))} rowKey={(r) => r.code} caption="Service categories" cols={[
        { key: 'label', label: 'Category' },
        { key: 'items', label: 'Records', className: 'wrap', render: (r) => r.is_service ? ((r.item_codes ?? []).map(label).join(', ') || 'A service with no item (other work)') : <span className="muted">not a service</span> },
        { key: 'act', label: '', render: (r) => <Act ops action="maint_category_save" payload={{ category_code: r.code }} label={r.is_service ? 'Change' : 'Make it a service'} title={r.label} refresh={R_} done="Saved." fields={[
          { name: 'item_codes', label: 'Items (comma separated codes)', type: 'list', value: r.item_codes ?? [], hint: s.items.map((i) => i.code).join(', ') },
          ...(r.is_service ? [{ name: 'remove', label: 'Not a service any more', type: 'bool' as const }] : [])]} /> }]} />
    </Card>
    <Card title="Reminders, km a day and the seasons" testId="maint-settings-program">
      <p className="small muted">One Fleet task per car with what is due, a To do line, and one line in the morning digest: no other email. Dates are month-day (12-01 is December 1). Saving writes a new dated row of Program settings.</p>
      <SaveForm table="program_settings" rowKey="current" testId="maint-program" fields={fieldsFrom(program, MAINT_KEYS.filter((k) => k in program))} />
    </Card>
  </>);
}
