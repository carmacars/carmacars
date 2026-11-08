import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { VehicleCard } from '@/features/owner/Blocks';
import { ownerView, requireOwner } from '@/server/owner/data';
import { carThisMonth, upcoming } from '@/features/owner/insights';
import { rpc } from '@/lib/db/repo';
import { OwnerTermsSummary } from '@/features/owner-billing/OwnerTerms';
import type { CarTermsData } from '@/features/owner-billing/terms-shared';
import { PortalTabs } from '@/features/portal-nav/PortalTabs';
import { tabOf } from '@/features/portal-nav/tabs';
import { OWNER_CARS_TABS } from '@/features/owner/menu';
import { BookingsTab } from './BookingsTab';
import { ReferredCars, type ReferredCar } from '@/features/owner/ReferredCars';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Cars', path: '/owner/vehicles', noindex: true, description: 'Your cars with CarmaCars and the bookings on them.' });

// Cars (r27 portals: Vehicles and Bookings were two menu links about the same cars). Your cars: where each is right now,
// this month so far, terms and what each still needs; Bookings: what is coming up, every booking, the calendar and booking
// your own car. /owner/bookings redirects to its tab with its query (?vehicle= for "Book it for myself").
export default async function OwnerCars({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([requireOwner('/owner/vehicles'), searchParams]);
  const { user, home } = ctx;
  // 0543: the cars of owners you referred, read only (an Admin links you to them); the tab shows only when there are some
  const referred = ((await rpc('server_owner_referred_cars', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as ReferredCar[] | null) ?? [];
  // 0640: a Referral Override Agreement waiting for this owner's signature
  const toSign = (((await rpc('server_referral_agreements', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as Array<{ link_id: string; referred: string; status: string }> | null) ?? []).filter((r) => r.status !== 'signed');
  const signNotice = toSign.length ? <section className="pt-card stack" data-testid="referral-agreement-to-sign"><h2 className="d4">Sign your Referral Override Agreement</h2>
    <ul className="ad-list">{toSign.map((r) => <li key={r.link_id}><Link prefetch={false} className="link" href={`/owner/referral-agreement/${r.link_id}`}>The cars of {r.referred}: read and sign</Link></li>)}</ul></section> : null;
  const tabs = referred.length ? [...OWNER_CARS_TABS, { key: 'referred', href: '/owner/vehicles?tab=referred', label: 'Cars you referred' }] : OWNER_CARS_TABS;
  if (sp.tab === 'referred' && referred.length) {
    return (
      <>
        <PageHeader title="Cars" purpose="The cars of the owners you referred: bookings, use and revenue, read only. Your referral share is on your statements." />
        <PortalTabs label="Cars" tabs={tabs} current="referred" />
        {signNotice}
        <ReferredCars cars={referred} />
      </>
    );
  }
  const tab = tabOf(OWNER_CARS_TABS, sp.tab);
  const add = home.kind !== 'partner' ? <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}><Link prefetch={false} className="btn btn--primary btn--sm" href="/list-your-car/apply">Add a vehicle</Link>
    {!home.fleet_supplier && <Link prefetch={false} className="btn btn--ghost btn--sm" href="/owner/vehicles/add" data-testid="owner-add-cars">Add cars from a VIN list</Link>}</span> : undefined;
  if (tab.key === 'bookings') {
    return (
      <>
        <PageHeader title="Cars" purpose="Every booking on your vehicles, and your own bookings of them." />
        <PortalTabs label="Cars" tabs={tabs} current={tab.key} />
        <BookingsTab {...ctx} vehicle={sp.vehicle} />
      </>
    );
  }
  // each car's terms and since when (0135)
  const terms = (await rpc('server_owner_car_terms', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as CarTermsData | null;
  const { months, live, photo, bookings } = await ownerView(user, home);
  const nextOf = (id: string) => upcoming(bookings.filter((b) => b.vehicle_id === id), new Date(), 1)[0] ?? null;
  return (
    <>
      <PageHeader title="Cars" purpose="Where each car is right now, this month so far, its terms and what it still needs. Open one for its months and bookings." action={add} />
      <PortalTabs label="Cars" tabs={tabs} current={tab.key} />
      {signNotice}
      {home.vehicles.length ? <ul className="ow-cars">{home.vehicles.map((v) => <VehicleCard key={v.vehicle_id} v={v} compact trackers={home.trackers_available} photo={photo[v.vehicle_id]} live={live[v.vehicle_id]} month={carThisMonth(months, v.vehicle_id)} next={nextOf(v.vehicle_id)} />)}</ul>
        : <div className="pt-empty"><p className="d4">No vehicles yet</p>{home.kind === 'partner' ? <p className="muted">CarmaCars adds your cars once we agree which ones join.</p> : <Link prefetch={false} className="btn btn--primary" href="/list-your-car/apply">Add your first vehicle</Link>}</div>}
      {terms && <OwnerTermsSummary data={terms} />}
    </>
  );
}
