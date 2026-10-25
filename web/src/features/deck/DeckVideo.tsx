import 'server-only';
import { env } from '@/lib/env';
import { DECK_VIDEO, DECK_VIDEO_TTL, deckVideoPaths, deckVideoUrls, type DeckVideoUrls } from './video-files';

// The narrated video of the deck (docs/investor-video/script.md), right above the deck. Its files are in a private
// bucket; each visit signs short-lived links here, on the server, after the page's own access check. No video (and no
// space kept for one) when the files are not uploaded yet or Storage does not answer in time.
async function signed(): Promise<DeckVideoUrls | null> {
  const e = env();
  if (e.DATA_BACKEND !== 'supabase' || !e.NEXT_PUBLIC_SUPABASE_URL || !e.SUPABASE_SERVICE_ROLE_KEY) return null;
  const api = `${e.NEXT_PUBLIC_SUPABASE_URL.replace(/\/$/, '')}/storage/v1`;
  try {
    const r = await fetch(`${api}/object/sign/${DECK_VIDEO.bucket}`, {
      method: 'POST', signal: AbortSignal.timeout(2500), cache: 'no-store',
      headers: { Authorization: `Bearer ${e.SUPABASE_SERVICE_ROLE_KEY}`, apikey: e.SUPABASE_SERVICE_ROLE_KEY, 'content-type': 'application/json' },
      body: JSON.stringify({ expiresIn: DECK_VIDEO_TTL, paths: deckVideoPaths() })
    });
    return r.ok ? deckVideoUrls(api, await r.json()) : null;
  } catch {
    return null;
  }
}

export async function DeckVideo() {
  const u = await signed();
  if (!u) return null;
  return (
    <section className="dk-video" aria-labelledby="dk-video-h" data-testid="deck-video">
      <div className="dk-video__head">
        <h2 className="d4" id="dk-video-h">Watch the deck</h2>
        <p className="small muted">The whole deck, narrated, in a few minutes. Captions are in the player. The slides follow below.</p>
      </div>
      <div className="dk-video__frame">
        <video controls preload="metadata" playsInline poster={u.poster} crossOrigin="anonymous" title="CarmaCars investor deck, narrated video"
          aria-label="CarmaCars investor deck, narrated video" data-testid="deck-video-player">
          <source src={u.hd} type="video/mp4" media="(min-width: 48rem)" />
          <source src={u.sd} type="video/mp4" />
          <track kind="captions" src={u.captions} srcLang="en" label="English" />
          <a className="link" href={u.sd}>Download the video</a>
        </video>
      </div>
    </section>
  );
}
