import { Act } from '@/features/admin/Act';
import { Card, Kv, t } from '@/features/admin/ui';
import { photoUrl } from '@/lib/photo';
import { genYears, sizePath, type StockPhoto } from './stock-photos';

// Admin > Settings > Vehicle pages, Stock photos (migration 0137): how far the licensed photos reach, every photo by
// make with its credit, and Hide, Show, Replace (a named Wikimedia Commons file) and Pick again. The seo-photos
// workflow adds photos every day and handles Replace and Pick again at its next run; nothing needs setting up.
type Row = StockPhoto & { kind: 'model' | 'generic'; slot: string | null; status: 'active' | 'hidden' | 'pending' | 'failed'; file_title: string; note: string | null;
  picked_by: string; want_file: string | null; checked_at: string };
export type StockData = {
  coverage: { models: number; models_checked: number; models_with_photo: number; model_years: number; model_years_with_photo: number; generations: number; model_only: number;
    hidden: number; pending: number; failed: number; generic: Record<string, number>; popular: number; popular_with_photo: number; popular_missing: string[];
    model_years_near?: number; model_years_model_only?: number; popular_with_generation?: number; sources?: Record<string, number>;
    last_run: { started_at: string; finished_at: string | null; counts: Record<string, number> | null; run_url: string | null } | null };
  photos: Row[];
};
const pct = (a: number, b: number) => (b ? `${Math.round((1000 * a) / b) / 10}%` : '0%');
const STATUS: Record<Row['status'], string> = { active: 'Shown', hidden: 'Hidden', pending: 'Waiting for the next run', failed: 'Not replaced' };

function PhotoRow({ r }: { r: Row }) {
  const small = r.path && r.sizes?.length ? photoUrl(sizePath(r, Math.min(...r.sizes))) : null;
  const what = r.kind === 'generic' ? `${r.slot} page` : `${r.model_name ?? r.model}${genYears(r) ? `, ${genYears(r)}` : ', the model in general'}`;
  return (
    <li className="stock-row" data-testid={`stock-row-${r.id}`}>
      {/* eslint-disable-next-line @next/next/no-img-element */}
      {small ? <img src={small} alt="" width={160} height={Math.round((160 * r.height) / r.width)} loading="lazy" decoding="async" /> : <span className="stock-row__none">No file</span>}
      <div className="stock-row__text">
        <b>{what}</b>{r.generation && r.kind === 'model' ? <span className="muted"> ({r.generation})</span> : null}
        <span className="small">Photo: <a className="link" href={r.source_url} target="_blank" rel="noopener">{r.author}</a>, {r.licence}, {r.source_name || 'Wikimedia Commons'}</span>
        <span className="xs muted">{STATUS[r.status]}{r.picked_by === 'admin' ? ', chosen by an Admin' : ''}{r.want_file ? `: ${r.want_file}` : ''}{r.note ? `. ${r.note}` : ''}. Checked {t(r.checked_at)}.</span>
        <span className="row stock-row__acts">
          {r.status === 'active' || r.status === 'pending' || r.status === 'failed'
            ? <Act action="stock_photo" payload={{ id: r.id, op: 'hide' }} label="Hide" done="Hidden. The page shows the studio drawing." testId={`stock-hide-${r.id}`} />
            : null}
          {r.status === 'hidden' && r.path ? <Act action="stock_photo" payload={{ id: r.id, op: 'show' }} label="Show" done="Shown again." testId={`stock-show-${r.id}`} /> : null}
          {r.kind === 'model' ? <>
            <Act action="stock_photo" payload={{ id: r.id, op: 'repick' }} label="Pick again" done="The next run picks another photo." testId={`stock-repick-${r.id}`} />
            <Act action="stock_photo" payload={{ id: r.id, op: 'replace' }} label="Replace" title={`Replace the photo of the ${what}`} done="The next run checks its licence and uses it."
              fields={[{ name: 'file', label: 'Wikimedia Commons file (its address or File:....jpg)', required: true, wide: true, placeholder: 'https://commons.wikimedia.org/wiki/File:...' }]} testId={`stock-replace-${r.id}`} />
          </> : null}
        </span>
      </div>
    </li>
  );
}

export function StockPhotosAdmin({ d }: { d: StockData }) {
  const c = d.coverage;
  const byMake = new Map<string, Row[]>();
  for (const r of d.photos) { const k = r.kind === 'generic' ? 'Place and service pages' : (r.make_name ?? r.make); byMake.set(k, [...(byMake.get(k) ?? []), r]); }
  const lr = c.last_run;
  return (
    <Card title={`Stock photos (${c.models_with_photo.toLocaleString('en-CA')} models)`} testId="vp-stock-photos">
      <p className="small muted">Licensed photos of each make, model and generation from Wikimedia Commons, or Openverse when Commons has none (public domain, CC0, CC BY or CC BY-SA only, an Openverse photo&apos;s licence checked again at its source), shown at the top of the vehicle pages with the credit always visible, and a few photos of roads, detailing and body shops on the place and service pages. Our own cars always show their own photos. The seo-photos workflow adds photos every day, our fleet&apos;s models and the popular models first; a year with no photo of its own generation shows the next generation&apos;s (a model year off) or another photo of the model, marked &ldquo;not the exact year&rdquo;; a model with no photo keeps the studio drawing. Turn them off with &ldquo;Show stock photos&rdquo; in the settings above.</p>
      <Kv rows={[
        ['Models with a photo', `${c.models_with_photo.toLocaleString('en-CA')} of ${c.models.toLocaleString('en-CA')} (${pct(c.models_with_photo, c.models)}); ${c.models_checked.toLocaleString('en-CA')} looked at so far`],
        ['Model years with a photo of their generation', `${c.model_years_with_photo.toLocaleString('en-CA')} of ${c.model_years.toLocaleString('en-CA')} (${pct(c.model_years_with_photo, c.model_years)}), in ${c.generations.toLocaleString('en-CA')} generations; ${(c.model_years_near ?? 0).toLocaleString('en-CA')} more a year off a generation, ${(c.model_years_model_only ?? 0).toLocaleString('en-CA')} with a photo of the model only`],
        ['Popular models with generation photos', `${c.popular_with_generation ?? 0} of ${c.popular}`],
        ['Sources', Object.entries(c.sources ?? {}).map(([k, n]) => `${k} ${n}`).join(', ')],
        ['Popular models', `${c.popular_with_photo} of ${c.popular} have a photo${c.popular_missing.length ? `. Missing: ${c.popular_missing.slice(0, 40).join(', ')}${c.popular_missing.length > 40 ? '...' : ''}` : ''}`],
        ['Place and service pages', Object.keys(c.generic).length ? Object.entries(c.generic).map(([k, n]) => `${k} ${n}`).join(', ') : 'None yet'],
        ['Hidden, waiting, not replaced', `${c.hidden}, ${c.pending}, ${c.failed}`],
        ['Last run', lr ? <>{t(lr.started_at)}{lr.counts ? `: ${lr.counts.models ?? 0} models, ${lr.counts.stored ?? 0} photos stored` : ' (running)'}{lr.run_url ? <>, <a className="link" href={lr.run_url} target="_blank" rel="noopener">GitHub Actions run</a></> : null}</> : 'None yet: the seo-photos workflow runs every day']
      ]} />
      {[...byMake.entries()].map(([make, rows]) => (
        <details key={make} data-testid={`stock-make-${make.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}>
          <summary className="link">{make} ({rows.length}{rows.some((r) => r.status !== 'active') ? `, ${rows.filter((r) => r.status !== 'active').length} not shown` : ''})</summary>
          <ul className="stock-list">{rows.map((r) => <PhotoRow key={r.id} r={r} />)}</ul>
        </details>))}
    </Card>
  );
}
