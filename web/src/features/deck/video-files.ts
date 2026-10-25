// The investor deck's narrated video (docs/investor-video/script.md): where its files are. Rendered and uploaded by
// .github/workflows/investor-video.yml to a PRIVATE Supabase Storage bucket, because the deck has no public version
// (docs/changes/2026-10-21-investor-deck.md): the deck page signs short-lived links on the server for each visit.
export const DECK_VIDEO = {
  bucket: 'investor-media',
  dir: 'deck-video',
  files: { hd: 'carmacars-investor-1080p.mp4', sd: 'carmacars-investor-720p.mp4', poster: 'poster.jpg', captions: 'captions.vtt' }
} as const;
export type DeckVideoFile = keyof typeof DECK_VIDEO.files;
export type DeckVideoUrls = Record<DeckVideoFile, string>;
/** How long a signed link lasts: long enough to watch the video more than once in one visit. */
export const DECK_VIDEO_TTL = 6 * 3600;

export const deckVideoPaths = () => (Object.keys(DECK_VIDEO.files) as DeckVideoFile[]).map((k) => `${DECK_VIDEO.dir}/${DECK_VIDEO.files[k]}`);

/** Storage's bulk sign answer ([{ path, signedURL, error }]) to the four links, or null when any file is missing. */
export function deckVideoUrls(storageApi: string, rows: unknown): DeckVideoUrls | null {
  if (!Array.isArray(rows)) return null;
  const api = storageApi.replace(/\/$/, '');
  const out: Partial<DeckVideoUrls> = {};
  for (const k of Object.keys(DECK_VIDEO.files) as DeckVideoFile[]) {
    const path = `${DECK_VIDEO.dir}/${DECK_VIDEO.files[k]}`;
    const row = rows.find((r): r is { signedURL?: string | null; error?: string | null } => !!r && typeof r === 'object' && (r as { path?: string }).path === path);
    const s = row?.signedURL;
    if (!s || row?.error) return null;
    out[k] = /^https?:\/\//.test(s) ? s : `${api}${s.startsWith('/') ? '' : '/'}${s}`;
  }
  return out as DeckVideoUrls;
}
