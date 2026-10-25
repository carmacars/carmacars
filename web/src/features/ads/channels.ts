// The channels a car is advertised on (migration 0167, docs/changes/2026-10-25-advertising-automation.md) and the limits
// the listing text keeps to on each. Only the website shows live prices and availability; every other channel carries
// "from" rates and a tracked link back to the car's page. Nothing here is posted by the server: Facebook Marketplace is
// posted from the owner's own profile in their browser, Kijiji and Craigslist by hand (their terms bar robots), and the
// Facebook Page and Instagram by hand until Meta publishing is switched on. Relative imports only (unit tests run in Node).

export type AdChannel = 'fb_marketplace' | 'kijiji' | 'craigslist' | 'instagram' | 'facebook_page' | 'google_business';

export interface ChannelSpec {
  key: AdChannel;
  label: string;
  /** the title field's limit (null: the channel has no title) */
  titleMax: number | null;
  /** the description, caption or post limit */
  bodyMax: number;
  /** photos the channel takes in one ad or post */
  photoMax: number;
  /** hashtags at the end of the text (0: none) */
  hashtags: number;
  /** a link in the text can be clicked (Instagram captions cannot: "link in bio") */
  linkInText: boolean;
  /** utm_medium of the tracked link */
  medium: string;
  /** what to do on the site, in a line */
  how: string;
}

export const CHANNELS: readonly ChannelSpec[] = [
  { key: 'fb_marketplace', label: 'Facebook Marketplace', titleMax: 100, bodyMax: 5000, photoMax: 10, hashtags: 0, linkInText: true, medium: 'marketplace',
    how: 'Posted from the owner\'s own Facebook profile in their browser (Meta does not take vehicle listings from business Pages). Paste the title, price and description, add the photos in this order.' },
  { key: 'kijiji', label: 'Kijiji', titleMax: 64, bodyMax: 4000, photoMax: 10, hashtags: 0, linkInText: true, medium: 'classified',
    how: 'One ad per car, in one category and one region (Kijiji removes duplicates). Paste the title and description, add the photos in this order.' },
  { key: 'craigslist', label: 'Craigslist', titleMax: 70, bodyMax: 4000, photoMax: 24, hashtags: 0, linkInText: true, medium: 'classified',
    how: 'Post in the Toronto area. Paste the posting title and the body, add the photos in this order.' },
  { key: 'instagram', label: 'Instagram', titleMax: null, bodyMax: 2200, photoMax: 10, hashtags: 10, linkInText: false, medium: 'social',
    how: 'A carousel post from the CarmaCars professional account. Links in captions cannot be clicked: put the link in the bio or a story link sticker.' },
  { key: 'facebook_page', label: 'Facebook Page', titleMax: null, bodyMax: 3000, photoMax: 10, hashtags: 3, linkInText: true, medium: 'social',
    how: 'A post on the CarmaCars Facebook Page with the photos and the link.' },
  { key: 'google_business', label: 'Google Business Profile', titleMax: null, bodyMax: 1500, photoMax: 1, hashtags: 0, linkInText: false, medium: 'post',
    how: 'An update post on the Google Business Profile with one photo and the button Book, linked to the address below. Google rejects phone numbers in the text.' }
];

export const channelOf = (k: string | null | undefined): ChannelSpec | undefined => CHANNELS.find((c) => c.key === k);
export const isChannel = (k: unknown): k is AdChannel => typeof k === 'string' && CHANNELS.some((c) => c.key === k);

/** Every channel the bookings report knows (app.ad_channel_label of 0167 says the same). */
export const REPORT_LABELS: Record<string, string> = {
  fb_marketplace: 'Facebook Marketplace', kijiji: 'Kijiji', craigslist: 'Craigslist', instagram: 'Instagram', facebook_page: 'Facebook Page', google_business: 'Google Business Profile',
  facebook: 'Facebook (other)', google: 'Google search', bing: 'Bing', other_site: 'Another website', direct: 'Direct (typed or bookmarked)', referral: 'Referral code',
  phone: 'Phone call', email: 'Email', whatsapp: 'WhatsApp', walk_in: 'Walk-in', repeat: 'Returning renter', word_of_mouth: 'Word of mouth', turo: 'Turo', other: 'Other', unknown: 'Not known'
};

/** The tracked link of a page for a channel: utm_source is the channel, utm_campaign the car code (or what the post is about). */
export function withUtm(url: string, source: string, medium: string, campaign: string | null | undefined): string {
  const u = new URL(url);
  u.searchParams.set('utm_source', source);
  u.searchParams.set('utm_medium', medium);
  if (campaign) u.searchParams.set('utm_campaign', campaign);
  return u.toString();
}

export function carPage(site: string, slug: string): string {
  return `${site.replace(/\/$/, '')}/cars/${encodeURIComponent(slug)}`;
}
