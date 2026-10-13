// OpenNext for a Cloudflare account without R2 (copied over web/open-next.config.ts by
// scripts/deploy/cloudflare.sh): cached pages and revalidateTag/revalidatePath in Workers KV,
// time-based revalidation queued through a Durable Object. All on Cloudflare's free plan.
import { defineCloudflareConfig } from '@opennextjs/cloudflare';
import kvIncrementalCache from '@opennextjs/cloudflare/overrides/incremental-cache/kv-incremental-cache';
import { withRegionalCache } from '@opennextjs/cloudflare/overrides/incremental-cache/regional-cache';
import doQueue from '@opennextjs/cloudflare/overrides/queue/do-queue';
import kvNextTagCache from '@opennextjs/cloudflare/overrides/tag-cache/kv-next-tag-cache';

export default defineCloudflareConfig({
  incrementalCache: withRegionalCache(kvIncrementalCache, { mode: 'long-lived' }),
  queue: doQueue,
  tagCache: kvNextTagCache,
  enableCacheInterception: true
});
