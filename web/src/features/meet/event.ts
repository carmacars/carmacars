// Release 37 (2303): the Google Calendar requests of an interview call with a Google Meet link. Pure (tested): the event
// body, the address of each call, and the Meet link read from Google's answer.
export const CALENDAR_SCOPE = 'https://www.googleapis.com/auth/calendar.events';
export const CALENDAR_API = 'https://www.googleapis.com/calendar/v3';

export interface MeetCall { id: string; sync: 'create' | 'update' | 'delete'; event_id: string | null; starts_at: string | null; ends_at: string | null; title: string; email: string | null }
export interface MeetRequest { method: 'POST' | 'PATCH' | 'DELETE'; url: string; body?: Record<string, unknown> }

/** The request for one call: create the event with a Meet conference, move it, or delete it (null: nothing to send). */
export function meetRequest(call: MeetCall, calendarId: string): MeetRequest | null {
  const cal = `${CALENDAR_API}/calendars/${encodeURIComponent(calendarId || 'primary')}/events`;
  // sendUpdates none: the candidate gets our own email with the link, never a second invitation from Google
  if (call.sync === 'delete') return call.event_id ? { method: 'DELETE', url: `${cal}/${encodeURIComponent(call.event_id)}?sendUpdates=none` } : null;
  if (!call.starts_at || !call.ends_at) return null;
  const when = { start: { dateTime: call.starts_at, timeZone: 'America/Toronto' }, end: { dateTime: call.ends_at, timeZone: 'America/Toronto' } };
  if (call.sync === 'update' && call.event_id) return { method: 'PATCH', url: `${cal}/${encodeURIComponent(call.event_id)}?conferenceDataVersion=1&sendUpdates=none`, body: when };
  return { method: 'POST', url: `${cal}?conferenceDataVersion=1&sendUpdates=none`, body: {
    summary: call.title, description: 'Interview call booked on the careers page. Join with the Google Meet link.', ...when,
    // the requestId makes a retried create the same conference, never a second one
    conferenceData: { createRequest: { requestId: `cc-${call.id}`, conferenceSolutionKey: { type: 'hangoutsMeet' } } },
    ...(call.email ? { attendees: [{ email: call.email }] } : {}),
    guestsCanInviteOthers: false, guestsCanSeeOtherGuests: false, reminders: { useDefault: true } } };
}

/** The Meet link in Google's answer (hangoutLink, or the conference's video entry point). */
export function meetLinkOf(ev: { hangoutLink?: string; conferenceData?: { entryPoints?: Array<{ entryPointType?: string; uri?: string }> } } | null | undefined): string | null {
  const uri = ev?.hangoutLink ?? ev?.conferenceData?.entryPoints?.find((e) => e.entryPointType === 'video')?.uri ?? null;
  return uri && /^https:\/\/meet\.google\.com\/[a-z0-9-]+$/.test(uri) ? uri : null;
}
