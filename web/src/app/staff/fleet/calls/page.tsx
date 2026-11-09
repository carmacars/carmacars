import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import type { PhoneInboxData } from '@/features/phone/client';
import { PhoneInbox } from '@/features/phone/PhoneInbox';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Calls and texts', path: '/staff/fleet/calls', noindex: true, description: "Fleet's lane: calls and texts about pickups, returns, deliveries and cars on rent." });

const ID = /^[0-9a-f-]{36}$/;
// r35 (0970): Fleet's own lane of the business phone. Calls and texts about pickups, returns, deliveries and cars on rent come
// here first (the caller pop-up rings for Fleet too); the database decides the lane (app.phone_lane) and who may read.
export default async function FleetCalls({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/staff/fleet/calls', ['fleet']), searchParams]);
  const inbox = await read<PhoneInboxData>('phone_inbox', { view: 'fleet' }).catch(() => null);
  return (
    <>
      <PageHead title="Calls and texts" purpose="Fleet's lane: calls and texts about pickups, returns, deliveries and cars on rent. Reply here from the CarmaCars number." />
      {inbox ? <PhoneInbox initial={inbox} portal="va" fn="fleet" openId={sp.id && ID.test(sp.id) ? sp.id : undefined} /> : <p className="small muted">Texts and calls are not open yet.</p>}
    </>
  );
}
