import { llmsResponse } from '@/features/seo/llms-route';
// The short map for AI answer engines (llmstxt.org), from the database (features/seo/facts.ts).
// rebuilt at most hourly like the home page (an ISR entry), so the Worker keeps an edge copy (src/lib/edge/page-cache.ts)
export const revalidate = 3600;
export const GET = () => llmsResponse(false);
