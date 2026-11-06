// The crawlers robots.txt names (docs/changes/2026-10-23-ai-search.md): the search engines, and the AI engines' search,
// answer and training crawlers, each by the token its company publishes (October 2026). All may read every public page;
// none may read the private ones. A crawler not listed still falls under "*" with the same rules.
const ANSWER_ALL = [
  // search engines (ChatGPT search and Copilot also read Bing's index; Brave and You.com have no token of their own)
  'Googlebot', 'Googlebot-Image', 'Bingbot', 'DuckDuckBot', 'Applebot', 'YandexBot', 'Yeti', 'SeznamBot', 'Baiduspider',
  // OpenAI: search, a person's request, training
  'OAI-SearchBot', 'ChatGPT-User', 'GPTBot',
  // Anthropic
  'Claude-SearchBot', 'Claude-User', 'ClaudeBot',
  // Perplexity
  'PerplexityBot', 'Perplexity-User',
  // Google: Gemini and AI Overviews training and grounding control, Vertex AI grounding, Deep Research, other products
  'Google-Extended', 'Google-CloudVertexBot', 'Gemini-Deep-Research', 'GoogleOther',
  // Apple Intelligence, Meta AI, Amazon (Alexa and Rufus), DuckDuckGo's DuckAssist, Mistral, Yandex's AI answers
  'Applebot-Extended', 'Meta-ExternalAgent', 'Meta-ExternalFetcher', 'Meta-WebIndexer', 'FacebookBot', 'Amazonbot', 'Amzn-SearchBot', 'Amzn-User',
  'DuckAssistBot', 'MistralAI-User', 'YandexAdditional', 'cohere-ai',
  // open crawls that feed many models
  'CCBot'
] as const;

// Never for crawlers: the portals, sign-in, the API, private files and links, and the query-string views of public pages.
export const PRIVATE_PATHS = [
  '/book', '/account', '/owner', '/investor', '/admin', '/staff', '/staff/field', '/go/', '/r/', '/unsubscribe', '/review/', '/email/', '/files/', '/d/', '/sign/', '/partners/portal/', '/careers/book/',
  '/sign-document/', '/guide-pdf/', '/sitemap-files/', '/sign-in', '/create-account', '/reset-password', '/update-password', '/two-step', '/choose-portal', '/read-only',
  '/link-expired', '/api/', '/auth/', '/cars?', '/cars/*?', '/car-rental/*?', '/guides/*?', '/rent/*?', '/buy/*?', '/detailing/*?', '/body-shop/*?'
] as const;

// 2026-10-30 (Worker requests and CPU): the training crawlers (no visitor comes from them) still read every public page,
// at most one page every CRAWL_DELAY_S seconds (Crawl-delay; ClaudeBot, Bing-based and Yandex crawlers honour it). The
// search and answer crawlers above keep no delay. A crawler named here is taken out of the group above.
export const SLOW_CRAWLERS = ['ClaudeBot', 'Meta-ExternalAgent', 'Meta-WebIndexer', 'FacebookBot', 'Amazonbot', 'GoogleOther', 'cohere-ai'] as const;
export const CRAWL_DELAY_S = 10;

// SEO tools and scrapers that bring no visitors and crawl the millions of car pages hardest: not welcome at all. The
// Worker entry answers them 403 before the app loads (src/lib/edge/bot-shield.ts BLOCKED_BOT), for those that ignore
// robots.txt (Bytespider does).
export const BLOCKED_CRAWLERS = ['AhrefsBot', 'SemrushBot', 'MJ12bot', 'DotBot', 'PetalBot', 'Bytespider', 'DataForSeoBot', 'BLEXBot', 'serpstatbot',
  'MegaIndex.ru', 'SeekportBot', 'Barkrowler', 'ImagesiftBot', 'Timpibot', 'ZoominfoBot', 'AwarioBot', 'magpie-crawler', 'SiteAuditBot', 'trendictionbot', 'Sogou web spider', 'MauiBot', 'AspiegelBot', 'LinkpadBot', 'Exabot', 'CCBot', 'GPTBot'] as const;

// The search and answer crawlers that bring visitors (docs/changes/2026-11-06-owner-todo-usage-noise.md). 0324, the owner's
// decision: every crawler reaches every page (about US$20 to 25 a month of CPU); the caching keeps it down (a crawler
// gets a page's last good copy or a 304). While the month's crawler guard is on (projected CPU cost above
// crawler_guard_usd, US$40), every crawler not named here keeps to the crawl scope (src/lib/edge/crawl-scope.ts) until the
// month ends; these never do. Keep in step with src/lib/edge/bot-shield.ts SEARCH_CRAWLER.
export const FULL_SCOPE_CRAWLERS = ['Googlebot', 'Googlebot-Image', 'Bingbot', 'DuckDuckBot', 'Applebot', 'OAI-SearchBot', 'ChatGPT-User', 'Claude-SearchBot', 'Claude-User',
  'PerplexityBot', 'Perplexity-User', 'Google-CloudVertexBot', 'Gemini-Deep-Research', 'Meta-ExternalFetcher', 'Amzn-SearchBot', 'Amzn-User', 'DuckAssistBot', 'MistralAI-User'] as const;

// 2026-11-06 (load hotfix): GPTBot and CCBot (training crawls, no visitors) are refused like the SEO scrapers above; the search and
// answer crawlers of the list keep full access.
export const ANSWER_CRAWLERS = ANSWER_ALL.filter((b) => !(BLOCKED_CRAWLERS as readonly string[]).includes(b));
