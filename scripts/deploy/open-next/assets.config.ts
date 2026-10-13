// OpenNext for a Cloudflare account with neither R2 nor KV access (copied over web/open-next.config.ts
// by scripts/deploy/cloudflare.sh): prerendered pages are served from the Worker's static assets as built
// (read-only: a page shows the data of the last deploy until the next deploy); dynamic pages render live.
import { defineCloudflareConfig } from '@opennextjs/cloudflare';
import staticAssetsIncrementalCache from '@opennextjs/cloudflare/overrides/incremental-cache/static-assets-incremental-cache';

export default defineCloudflareConfig({
  incrementalCache: staticAssetsIncrementalCache,
  enableCacheInterception: true
});
