import { Act } from '@/features/admin/Act';
import { $, Card, d } from '@/features/admin/ui';

// Referral links between owners (migration 0543): the owner who referred another gets a share of the revenue base of
// the referred owner's cars on each statement (a "Referral share" line per car) and, when allowed, sees those cars read
// only in the owner portal. Any two owners; an Admin sets the share in points (10 = 10% of the revenue the fee is taken from).
export interface ReferralLinksData {
  owners: Array<{ id: string; name: string }>;
  links: Array<{ id: string; referrer_owner_id: string; referred_owner_id: string; referrer: string; referred: string; share_bps: number; sees_cars: boolean;
    effective_from: string; effective_to: string | null; note: string | null; paid_cents: number; cars: number }>;
}

export function ReferralLinks({ data, ownerId }: { data: ReferralLinksData; ownerId: string }) {
  const refresh = [`/admin/owners/${ownerId}`];
  const others = data.owners.filter((o) => o.id !== ownerId).map((o) => [o.id, o.name] as [string, string]);
  return (
    <Card title="Referral links" testId="referral-links">
      <p className="small">An owner who referred another owner: a share of the revenue of the referred owner&apos;s cars on every statement (one line per car; it comes out of CarmaCars&apos; share, never the referred owner&apos;s payout), and a read-only view of those cars in the owner portal (no personal details). Set the referred owner&apos;s own fee on their Terms tab (for example 40% and $350 a month per car); the share here is usually the points above the standard 30%.</p>
      {data.links.length ? <ul className="ad-list" data-testid="referral-link-rows">{data.links.map((l) => (
        <li key={l.id}><span>{l.referrer_owner_id === ownerId ? <>Referred <b>{l.referred}</b></> : <>Referred by <b>{l.referrer}</b></>} · {(l.share_bps / 100).toFixed(l.share_bps % 100 ? 2 : 0)} points · {l.cars} car{l.cars === 1 ? '' : 's'} · {l.sees_cars ? 'sees the cars' : 'does not see the cars'} · from {d(l.effective_from)}{l.effective_to ? ` to ${d(l.effective_to)}` : ''} · paid {$(l.paid_cents)}</span>
          {!l.effective_to && <span className="row">
            <Act action="owner_referral_link_save" payload={{ id: l.id }} label="Change" refresh={refresh} done="Saved." submitLabel="Save"
              fields={[{ name: 'share_bps', label: 'Share (basis points: 1000 = 10 points)', type: 'number', required: true, value: l.share_bps },
                { name: 'sees_cars', label: 'The referrer sees the cars (read only)', type: 'bool', value: l.sees_cars }, { name: 'note', label: 'Note', value: l.note ?? '' }]} />
            <Act action="owner_referral_link_save" payload={{ id: l.id, end: true }} label="End" confirm="End this referral link? Shares already earned are still paid." refresh={refresh} done="Ended." /></span>}
        </li>))}</ul> : <p className="small muted">No referral links.</p>}
      <Act action="owner_referral_link_save" payload={{ referrer_owner_id: ownerId }} label="This owner referred another owner" variant="primary" refresh={refresh} done="Referral link saved." submitLabel="Save" testId="referral-link-add"
        fields={[{ name: 'referred_owner_id', label: 'The owner referred', type: 'select', required: true, options: others },
          { name: 'share_bps', label: 'Share (basis points: 1000 = 10 points of the revenue)', type: 'number', required: true, value: 1000 },
          { name: 'sees_cars', label: 'This owner sees the referred owner\'s cars (read only)', type: 'bool', value: true },
          { name: 'effective_from', label: 'From (the first statement month)', type: 'date' }, { name: 'note', label: 'Note' }]} />
    </Card>
  );
}
