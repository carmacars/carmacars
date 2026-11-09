import 'server-only';
import { door } from '@/server/door';
import type { AdPhoto } from '@/features/ads/listing';

/** r35 S2 (1053): the made photos of a car's newest marketing set, in order (the database checks who may read them). */
export async function scenePhotos(user: string, vehicle: string, aal?: 'aal1' | 'aal2' | null): Promise<AdPhoto[]> {
  const d = await door<{ photos: Array<{ status: string; path: string | null; scene: string; shot: string }> }>(user, 'ops_read', 'marketing_photos', { vehicle }, aal);
  return d.photos.filter((p) => p.status === 'made' && p.path).map((p) => ({ path: p.path!, label: p.scene, shot: p.shot }));
}
