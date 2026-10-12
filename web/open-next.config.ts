// OpenNext for Cloudflare Workers (docs/decisions/0001-zero-fixed-fee-stack.md).
// Cached pages live in R2; time-based revalidation is queued through a Durable Object;
// revalidateTag is tracked in D1. All three are on Cloudflare's free plan.
import { defineCloudflareConfig } from '@opennextjs/cloudflare';
import r2IncrementalCache from '@opennextjs/cloudflare/overrides/incremental-cache/r2-incremental-cache';
import { withRegionalCache } from '@opennextjs/cloudflare/overrides/incremental-cache/regional-cache';
import doQueue from '@opennextjs/cloudflare/overrides/queue/do-queue';
import d1NextTagCache from '@opennextjs/cloudflare/overrides/tag-cache/d1-next-tag-cache';

export default defineCloudflareConfig({
  incrementalCache: withRegionalCache(r2IncrementalCache, { mode: 'long-lived' }),
  queue: doQueue,
  tagCache: d1NextTagCache,
  enableCacheInterception: true
});
