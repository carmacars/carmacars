import { notFound, permanentRedirect } from 'next/navigation';
import { rpc } from '@/lib/db/repo';

// The old model hubs (0022): /rent/<make-model> now answers 301 with the model's vehicle page, /cars/<make>/<model>
// (migration 0097, public.vehicle_hub_path), so links and search results keep working.
export const revalidate = 3600;
export const dynamicParams = true;
export async function generateStaticParams() { return []; }
type Params = { params: Promise<{ hub: string }> };

export default async function HubPage({ params }: Params) {
  const hub = (await params).hub;
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(hub)) notFound();
  const to = (await rpc('vehicle_hub_path', { p_hub: hub })) as unknown as string | null;
  if (!to) notFound();
  permanentRedirect(to);
}
