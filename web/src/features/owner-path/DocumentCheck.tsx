import Link from '@/components/Link';

// r50 (3820): Admin > Owners > Document check. Everything still inconsistent on the owners' documents (a title that is a
// name, a method that does not fit how the car is held, a first and last month off the rule, an empty value a document
// prints, insurance with HST, a signed copy being filed again), by owner, each with what fixes it. The database reads it
// (app.owner_documents_check); the connector has the same (owner_documents_check).
export interface DocIssue { owner_id: string; name: string; vehicle_id: string | null; code: string; label: string; fix: string | null }
export interface DocCheck { items: DocIssue[]; count: number; by_issue: Record<string, number>; by_owner: Array<{ owner_id: string; name: string; count: number }> }

export const ISSUE: Record<string, string> = {
  title_is_name: 'Title is a name', profile_missing: 'Profile incomplete', corporation_number: 'No corporation number', method_mismatch: 'Method does not fit',
  co_registrant_check: 'Co-Registrant to confirm', first_last_rule: 'First and last off the rule', schedule_empty: 'Empty on the schedule',
  countersignature: 'Copy being filed again', insurance_hst: 'HST on insurance'
};

export function DocumentCheck({ data }: { data: DocCheck }) {
  if (!data.count) return <p className="pt-empty muted" data-testid="doc-check-clear">Every owner&apos;s documents are consistent.</p>;
  const owners = data.by_owner;
  return (
    <div className="stack" data-testid="doc-check">
      <p className="small">{data.count} to look at: {Object.entries(data.by_issue).map(([k, n]) => `${ISSUE[k] ?? k} ${n}`).join(' · ')}.</p>
      <ul className="ow-rows">{owners.map((o) => (
        <li key={o.owner_id} data-owner={o.owner_id}>
          <Link prefetch={false} className="ow-row-link" href={`/admin/owners/${o.owner_id}?tab=terms`}>{o.name}</Link>
          <span className="ow-meta"><span>{o.count} to look at</span></span>
          <ul className="ad-list small" style={{ flex: '1 1 100%' }}>{data.items.filter((i) => i.owner_id === o.owner_id).map((i, n) => (
            <li key={`${i.code}-${i.vehicle_id ?? ''}-${n}`} data-code={i.code}><span><span className="badge badge--outline">{ISSUE[i.code] ?? i.code}</span> {i.label}</span>{i.fix && <span className="muted">{i.fix}</span>}</li>))}</ul>
        </li>))}</ul>
    </div>
  );
}
