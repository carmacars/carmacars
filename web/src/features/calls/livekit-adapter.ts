// The company's own media server (CALLS_PROVIDER=livekit; infra/vps/livekit): LiveKit's browser client, loaded only on a
// call page. Audio of the others plays through elements the session keeps off screen; video is attached to the tiles.
import { Room, RoomEvent, Track, type Participant, type RemoteTrack } from 'livekit-client';
import { parseMsg, type CallRole, type MediaSession, type Msg, type Person, type Received, type Ticket } from './adapter';

const roleOf = (p: Participant, fallback: CallRole): CallRole => {
  try { const r = (JSON.parse(p.metadata || '{}') as { role?: CallRole }).role; return r ?? fallback; } catch { return fallback; }
};

export function livekitSession(t: Ticket): MediaSession {
  const room = new Room({ adaptiveStream: true, dynacast: true, publishDefaults: { simulcast: true } });
  const audio = document.createElement('div');
  audio.hidden = true;
  let change: () => void = () => {};
  let message: (r: Received) => void = () => {};
  let ended: (why: string) => void = () => {};
  const person = (p: Participant, local: boolean): Person => ({
    identity: p.identity, name: p.name || p.identity, role: roleOf(p, local ? t.role : 'member'), local,
    mic: p.isMicrophoneEnabled, cam: p.isCameraEnabled, screen: p.isScreenShareEnabled, speaking: p.isSpeaking });
  const ping = () => change();
  room.on(RoomEvent.ParticipantConnected, ping).on(RoomEvent.ParticipantDisconnected, ping).on(RoomEvent.TrackMuted, ping).on(RoomEvent.TrackUnmuted, ping)
    .on(RoomEvent.LocalTrackPublished, ping).on(RoomEvent.LocalTrackUnpublished, ping).on(RoomEvent.ActiveSpeakersChanged, ping).on(RoomEvent.TrackUnsubscribed, ping)
    .on(RoomEvent.TrackSubscribed, (track: RemoteTrack) => { if (track.kind === Track.Kind.Audio) audio.appendChild(track.attach()); ping(); })
    .on(RoomEvent.ParticipantMetadataChanged, ping)
    .on(RoomEvent.DataReceived, (payload: Uint8Array, p?: Participant) => {
      if (!p) return;
      let raw: unknown = null;
      try { raw = JSON.parse(new TextDecoder().decode(payload)); } catch { return; }
      const m = parseMsg(raw);
      if (m) message({ from: p.identity, name: p.name || p.identity, msg: m });
    })
    .on(RoomEvent.Disconnected, (reason?: unknown) => { audio.remove(); ended(String(reason ?? 'disconnected')); });
  return {
    async connect() {
      document.body.appendChild(audio);
      await room.connect(t.url!, t.token!, { autoSubscribe: true });
      await room.startAudio().catch(() => undefined);
      change();
    },
    disconnect() { void room.disconnect(); },
    async setMic(on) { await room.localParticipant.setMicrophoneEnabled(on); change(); },
    async setCam(on) { await room.localParticipant.setCameraEnabled(on); change(); },
    async setScreen(on) { await room.localParticipant.setScreenShareEnabled(on, { audio: true }); change(); },
    send(m: Msg) { void room.localParticipant.publishData(new TextEncoder().encode(JSON.stringify(m)), { reliable: true }); },
    people: () => [person(room.localParticipant, true), ...[...room.remoteParticipants.values()].map((p) => person(p, false))],
    attach(identity, source, el) {
      const p = identity === room.localParticipant.identity ? room.localParticipant : room.remoteParticipants.get(identity);
      const pub = p?.getTrackPublication(source === 'screen' ? Track.Source.ScreenShare : Track.Source.Camera);
      const track = pub?.track;
      if (!track || pub?.isMuted) return false;
      track.attach(el);
      return true;
    },
    onChange(f) { change = f; },
    onMessage(f) { message = f; },
    onEnded(f) { ended = f; },
  };
}
