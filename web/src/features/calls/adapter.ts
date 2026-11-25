// The calls in the site (r50, 5010): the media seam. The page talks to a MediaSession; LiveKit (the company's own server)
// and Fake (no media: the browser's BroadcastChannel carries who is here and the data messages, for CI and local
// development) implement it, like the other provider seams. Pure where it can be: the message rules are unit tested.
export type CallRole = 'presenter' | 'host' | 'member' | 'guest';
export interface Ticket { provider: 'livekit' | 'fake' | 'off'; url: string | null; token: string | null; room: string; identity: string; name: string; role: CallRole }
export interface Person { identity: string; name: string; role: CallRole; local: boolean; mic: boolean; cam: boolean; screen: boolean; speaking: boolean }

/** What travels on the data channel. Chat is kept to 500 characters; a slide index to the deck. */
export type Msg =
  | { t: 'slide'; i: number }
  | { t: 'ask' }
  | { t: 'chat'; id: string; text: string; at: number }
  | { t: 'hand'; up: boolean };
export interface Received { from: string; name: string; msg: Msg }

export interface MediaSession {
  connect(): Promise<void>;
  disconnect(): void;
  setMic(on: boolean): Promise<void>;
  setCam(on: boolean): Promise<void>;
  setScreen(on: boolean): Promise<void>;
  send(m: Msg): void;
  people(): Person[];
  /** the person's camera (or screen) into the element; returns false when there is none */
  attach(identity: string, source: 'camera' | 'screen', el: HTMLVideoElement): boolean;
  onChange(f: () => void): void;
  onMessage(f: (r: Received) => void): void;
  onEnded(f: (why: string) => void): void;
}

/** A message from the channel, checked: anything else is dropped (a peer cannot send the page something else). */
export function parseMsg(raw: unknown): Msg | null {
  const m = raw as Record<string, unknown> | null;
  if (!m || typeof m !== 'object') return null;
  if (m.t === 'slide' && Number.isInteger(m.i) && (m.i as number) >= 0 && (m.i as number) < 200) return { t: 'slide', i: m.i as number };
  if (m.t === 'ask') return { t: 'ask' };
  if (m.t === 'hand' && typeof m.up === 'boolean') return { t: 'hand', up: m.up };
  if (m.t === 'chat' && typeof m.id === 'string' && /^[\w-]{4,40}$/.test(m.id) && typeof m.text === 'string' && m.text.trim() && typeof m.at === 'number') {
    return { t: 'chat', id: m.id, text: m.text.trim().slice(0, 500), at: m.at };
  }
  return null;
}

/** Only the presenter moves everyone's slide; anyone may ask for it. */
export function acceptSlide(fromRole: CallRole | undefined, m: Msg): boolean {
  return m.t === 'slide' && fromRole === 'presenter';
}

/** The tiles in order: whoever shares a screen first, then the presenter or host, then the others by name; me last. */
export function orderPeople(p: Person[]): Person[] {
  const rank = (x: Person) => (x.screen ? 0 : x.role === 'presenter' || x.role === 'host' ? 1 : x.local ? 3 : 2);
  return [...p].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
}

/** The session for the ticket the server gave. */
export async function openSession(t: Ticket): Promise<MediaSession> {
  if (t.provider === 'livekit') return (await import('./livekit-adapter')).livekitSession(t);
  if (t.provider === 'fake') return (await import('./fake-adapter')).fakeSession(t);
  throw new Error('Calls in the site are off: use the outside call link');
}
