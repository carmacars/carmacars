import { Act, SaveForm } from '@/features/admin/Act';
import { fieldsFrom } from '@/features/admin/fields';
import { Card, Kv, Table, t } from '@/features/admin/ui';
import { gateRules, type GateSettings } from './gate';

// Admin > Settings > Vehicle pages (migration 0092): how many pages there are and how many are indexed, the settings
// (indexing, gas and electricity prices, how often the catalog is imported), the popular list, the Canadian trims of
// each model, the last import and Import now. Nothing here needs setting up: every page is indexed by default.
export type VpData = {
  settings: GateSettings & { gas_cents: number; elec_cents: number; premium_extra_cents: number };
  counts: Record<string, { total: number; indexed: number }>; sitemaps: number; makes: number; models: number;
  last_import: { id: string; status: string; started_at: string; finished_at: string | null; counts: Record<string, number> | null; error: string | null; stats: Record<string, number> | null; run_url: string | null } | null;
  last_done: string | null; requested: string | null;
  popular: Array<{ make: string; model: string; name: string; in_catalog: boolean }>;
  trim_models: Array<{ make: string; model: string; name: string; source: string; lines: string }>;
};
const LEVELS: Array<[string, string]> = [['make', 'Makes'], ['model', 'Models'], ['year', 'Model years'], ['trim', 'Trims']];
const KEYS = ['vpage_index_mode', 'vpage_model_min_years', 'vpage_popular_from_year', 'vpage_year_min_cars', 'vpage_trim_min_cars',
  'vpage_gas_cents_per_litre', 'vpage_premium_extra_cents', 'vpage_electricity_cents_per_kwh', 'vpage_import_every_days'];

export function VehiclePagesAdmin({ d, program }: { d: VpData; program: Record<string, unknown> }) {
  const rows = LEVELS.map(([k, label]) => ({ level: label, total: d.counts[k]?.total ?? 0, indexed: d.counts[k]?.indexed ?? 0, noindex: (d.counts[k]?.total ?? 0) - (d.counts[k]?.indexed ?? 0) }));
  const total = rows.reduce((n, r) => n + r.total, 0), indexed = rows.reduce((n, r) => n + r.indexed, 0);
  const li = d.last_import;
  return (<>
    <p className="small muted">A page for every make, model, model year and Canadian trim at /cars/make/model/year/trim, with our cars below it. Specs and fuel use come from the US EPA catalog, model names from NHTSA vPIC, trim names from the CarmaCars list of Canadian trims (edit below). The catalog is imported by itself every {String(program.vpage_import_every_days ?? 30)} days.</p>
    <Card title="Pages" testId="vp-counts">
      <Table rows={rows} rowKey={(r) => String(r.level)} cols={[{ key: 'level', label: 'Level' }, { key: 'total', label: 'Pages', num: true }, { key: 'indexed', label: 'Indexed', num: true }, { key: 'noindex', label: 'Not indexed', num: true }]} />
      <Kv rows={[['Total', `${total.toLocaleString('en-CA')} pages, ${indexed.toLocaleString('en-CA')} indexed, in ${d.sitemaps} sitemaps`], ['Rules now', gateRules(d.settings).map(([, r]) => r).join(' ')]]} />
    </Card>
    <Card title="Catalog import" testId="vp-import">
      <Kv rows={[['Last import', li ? `${li.status === 'done' ? 'Done' : li.status === 'failed' ? 'Failed' : 'Running'}, started ${t(li.started_at)}${li.finished_at ? `, finished ${t(li.finished_at)}` : ''}` : 'None yet: the catalog workflow fills it'],
        ['Catalog', li?.counts ? `${li.counts.makes} makes, ${li.counts.models} models, ${li.counts.years} model years, ${li.counts.trims} trims` : `${d.makes} makes, ${d.models} models`],
        ['Error', li?.error ?? ''], ['Run', li?.run_url ? <a className="link" href={li.run_url} target="_blank" rel="noopener">GitHub Actions run</a> : ''],
        ['Asked for', d.requested ? `${t(d.requested)}: the import starts at the next daily check (07:17 UTC)` : '']]} />
      <Act action="vehicle_pages_import" label="Import now" variant="primary" done="Asked for. The import runs at the next daily check." testId="vp-import-now" />
    </Card>
    <Card title="Settings" testId="vp-settings">
      <p className="small muted">Index everything is the default. Choose rules to index only the pages that pass them; the others stay visible with noindex,follow and their canonical at the parent page. Saving writes a new dated row of the program settings.</p>
      <SaveForm table="program_settings" rowKey="current" testId="vp-settings-form" fields={fieldsFrom(program, KEYS, { vpage_index_mode: [['all', 'Index every page'], ['rules', 'Only pages that pass the rules']] })} />
    </Card>
    <Card title={`Popular models (${d.popular.length})`} testId="vp-popular">
      <p className="small muted">Used by the rules only: a model year of a popular model from the set year on is indexed. One model per line, most popular first, for example &ldquo;Toyota RAV4&rdquo;. Models the catalog does not have are left out.</p>
      <Act action="vehicle_pages_popular" label="Save the popular list" inline testId="vp-popular-form" done="Saved."
        fields={[{ name: 'lines', label: 'Popular models', type: 'textarea', wide: true, value: d.popular.map((p) => p.name).join('\n') }]} />
    </Card>
    <Card title={`Canadian trims (${d.trim_models.length} models)`} testId="vp-trims">
      <p className="small muted">One line per run of years, entry trim first: &ldquo;2020-2021: Comfortline, Highline, Sportline, Execline&rdquo;. Your lines replace the list&apos;s for that model and are kept by every import; empty them to go back to the list.</p>
      {d.trim_models.map((m) => (
        <details key={`${m.make}/${m.model}`}><summary className="link">{m.name}{m.source === 'admin' ? ' (edited)' : ''}</summary>
          <Act action="vehicle_pages_trims" payload={{ make: m.make, model: m.model }} label={`Save ${m.name} trims`} inline done="Saved. The trim pages are rebuilt."
            fields={[{ name: 'lines', label: 'Trim lines', type: 'textarea', wide: true, value: m.lines }]} /></details>))}
      <Act action="vehicle_pages_trims" label="Add trims for another model" title="Trims for a model" testId="vp-trims-add"
        fields={[{ name: 'make', label: 'Make (as in its address, e.g. toyota)', required: true }, { name: 'model', label: 'Model (as in its address, e.g. rav4)', required: true },
          { name: 'lines', label: 'Trim lines', type: 'textarea', required: true, wide: true, placeholder: '2019-2024: LE, XLE, Limited' }]} />
    </Card>
  </>);
}
