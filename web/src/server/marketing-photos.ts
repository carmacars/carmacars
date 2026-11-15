import 'server-only';
import { door } from '@/server/door';
import type { AdPhoto } from '@/features/ads/listing';

/** r35 S2 (1053): the made photos of a car's newest marketing set, in order (the database checks who may read them). */
/** r48 (3030): `pick`, the ids of the photos chosen for one post (2 or 3 lifestyle shots, say); every made photo without it. */
export async function scenePhotos(user: string, vehicle: string, aal?: 'aal1' | 'aal2' | null, pick?: readonly string[] | null): Promise<AdPhoto[]> {
  const d = await door<{ photos: Array<{ id: string; status: string; path: string | null; scene: string; shot: string }> }>(user, 'ops_read', 'marketing_photos', { vehicle }, aal);
  const want = pick?.length ? new Set(pick) : null;
  return d.photos.filter((p) => p.status === 'made' && p.path && (!want || want.has(p.id))).map((p) => ({ path: p.path!, label: p.scene, shot: p.shot }));
}
