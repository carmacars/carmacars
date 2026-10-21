// Wraps OpenNext's tag cache (open-next.config.ts): after a page is rebuilt on demand (revalidatePath, revalidateTag),
// the edge copy's generation number moves on, so the Worker entry stops serving copies kept before it
// (src/lib/edge/page-cache.ts). Portal-only rebuilds (the admin, renter, owner and staff pages) leave it alone.
import { getCloudflareContext } from '@opennextjs/cloudflare';
import { bumpGeneration, tagsTouchPublic } from './page-cache';

type Tag = string | { tag: string };
interface TagCacheLike { writeTags(tags: Tag[]): Promise<void> }

export function withEdgeGeneration<T extends TagCacheLike>(tagCache: T): T {
  const write = tagCache.writeTags.bind(tagCache);
  tagCache.writeTags = async (tags: Tag[]) => {
    await write(tags);
    if (!tagsTouchPublic(tags)) return;
    try { await bumpGeneration(getCloudflareContext().env as unknown as Record<string, unknown>); } catch { /* the copies then live out their hour */ }
  };
  return tagCache;
}
