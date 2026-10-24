// Live visitors (0086): what a component tells the beacon (the price shown, photos looked through). The beacon loads once
// the page is idle (src/features/live/SiteAssist.tsx), often after the price is already on screen: an event from before
// it started waits on the page (at most 20) and the beacon takes it when it starts (release 4 checks).
export type TrackDetail = { k: string; d?: Record<string, string> };
type W = Window & { __ccTrack?: TrackDetail[]; __ccBeacon?: boolean };

export function emitTrack(detail: TrackDetail) {
  const w = window as W;
  if (!w.__ccBeacon) { (w.__ccTrack ??= []).push(detail); if (w.__ccTrack.length > 20) w.__ccTrack.shift(); return; }
  window.dispatchEvent(new CustomEvent('cc:track', { detail }));
}
/** The beacon has started: the events that waited, in order; later ones come as cc:track events. */
export function takeWaitingTracks(): TrackDetail[] {
  const w = window as W;
  w.__ccBeacon = true;
  const out = w.__ccTrack ?? [];
  w.__ccTrack = [];
  return out;
}
