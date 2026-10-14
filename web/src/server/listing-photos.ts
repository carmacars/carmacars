import 'server-only';
import { storage } from '@/integrations/storage';

/** Originals are in the private vehicle-originals bucket: a reviewer sees them through 15-minute signed links
 *  (a photo the pipeline has not edited yet, or a shot that is never published, such as the odometer). */
export async function withOriginalUrls<T extends { photos: Array<{ original_path: string | null; processed_path: string | null }> }>(l: T): Promise<T> {
  const s = await storage();
  const photos = await Promise.all(l.photos.map(async (p) => ({ ...p, original_url: p.original_path ? await s.signedDownloadUrl('vehicle-originals', p.original_path, 900).catch(() => null) : null })));
  return { ...l, photos };
}
