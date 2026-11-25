// r50 (5050): the addresses of a private shift calendar feed. Pure: the card and the unit test read it.
export type FeedScope = 'all' | 'mine';
export interface Feed { scope: FeedScope; token: string | null; created_at: string | null }
export interface FeedState { scopes: FeedScope[]; feeds: Feed[] }

const TOKEN = /^[0-9a-f]{64}$/;

/** The https address of a feed (what a calendar app downloads). */
export function feedUrl(site: string, token: string): string {
  if (!TOKEN.test(token)) throw new Error('Not a feed token');
  return `${site.replace(/\/$/, '')}/api/shift-feed/${token}.ics`;
}

/** The same address as webcal://, which calendar apps open as a subscription. */
export const webcalUrl = (url: string) => url.replace(/^https?:\/\//, 'webcal://');

/** Google Calendar's "add by URL" page with the feed filled in: one click, then Add. */
export const googleAddUrl = (url: string) => `https://calendar.google.com/calendar/r?cid=${encodeURIComponent(webcalUrl(url))}`;

export const SCOPE_WORDS: Record<FeedScope, { title: string; lead: string }> = {
  all: { title: 'Add shifts to Google Calendar', lead: 'Every field shift, 14 days back to 60 days ahead: who claimed it or Open, the tasks on it, and a link to it.' },
  mine: { title: 'Add my shifts to Google Calendar', lead: 'The shifts you claimed, 14 days back to 60 days ahead, with the tasks given to you.' }
};
