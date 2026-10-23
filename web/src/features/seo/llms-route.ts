import 'server-only';
import { getEntityFacts } from './facts';
import { llmsFullTxt, llmsTxt } from './llms';

// /llms.txt and /llms-full.txt (docs/changes/2026-10-23-ai-search.md): Markdown served as text/plain (what every fetcher
// reads), rebuilt at most hourly (the routes' revalidate) like the home page.
export async function llmsResponse(full: boolean): Promise<Response> {
  const body = (full ? llmsFullTxt : llmsTxt)(await getEntityFacts());
  return new Response(body, { headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=3600, s-maxage=3600', 'x-robots-tag': 'noindex' } });
}
