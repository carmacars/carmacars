// The crawlers robots.txt names (docs/changes/2026-10-23-ai-search.md): the search engines, and the AI engines' search,
// answer and training crawlers, each by the token its company publishes (October 2026). All may read every public page;
// none may read the private ones. A crawler not listed still falls under "*" with the same rules.
export const ANSWER_CRAWLERS = [
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
  '/book', '/account', '/owner', '/investor', '/admin', '/va', '/field', '/go/', '/r/', '/unsubscribe', '/review/', '/email/', '/files/', '/d/', '/sign/', '/partners/portal/', '/careers/book/',
  '/sign-document/', '/guide-pdf/', '/sitemap-files/', '/sign-in', '/create-account', '/reset-password', '/update-password', '/two-step', '/choose-portal', '/read-only',
  '/link-expired', '/api/', '/auth/', '/cars?', '/cars/*?', '/car-rental/*?', '/guides/*?', '/rent/*?', '/buy/*?', '/detailing/*?', '/body-shop/*?'
] as const;

// 2026-10-30 (Worker requests and CPU): the training crawlers (no visitor comes from them) still read every public page,
// at most one page every CRAWL_DELAY_S seconds (Crawl-delay; ClaudeBot, Bing-based and Yandex crawlers honour it). The
// search and answer crawlers above keep no delay. A crawler named here is taken out of the group above.
export const SLOW_CRAWLERS = ['GPTBot', 'ClaudeBot', 'CCBot', 'Meta-ExternalAgent', 'Meta-WebIndexer', 'FacebookBot', 'Amazonbot', 'GoogleOther', 'cohere-ai'] as const;
export const CRAWL_DELAY_S = 10;

// SEO tools and scrapers that bring no visitors and crawl the millions of car pages hardest: not welcome at all. The
// Worker entry answers them 403 before the app loads (src/lib/edge/bot-shield.ts BLOCKED_BOT), for those that ignore
// robots.txt (Bytespider does).
export const BLOCKED_CRAWLERS = ['AhrefsBot', 'SemrushBot', 'MJ12bot', 'DotBot', 'PetalBot', 'Bytespider', 'DataForSeoBot', 'BLEXBot', 'serpstatbot',
  'MegaIndex.ru', 'SeekportBot', 'Barkrowler', 'ImagesiftBot', 'Timpibot', 'ZoominfoBot', 'AwarioBot', 'magpie-crawler', 'SiteAuditBot', 'trendictionbot', 'Sogou web spider'] as const;
