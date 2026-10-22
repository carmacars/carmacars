// Sample webhook deliveries (migration 0085). The current ones are the `data` samples of Quo's documentation,
// "Webhook event payloads" (quo.com/docs/2026-03-30/webhooks-event-payloads), with the envelope fields (id, apiVersion,
// createdAt) added and the outside number set to a test number; the legacy ones follow the shape of OpenPhone's v1
// webhooks (data.object). Used by the unit tests, the database test fixtures and the end-to-end mock.

const ctx = (extra: Record<string, unknown> = {}) => ({
  orgId: 'OR123', phoneNumberId: 'PN123', conversationId: 'CN123', phoneNumberType: 'shared', userId: 'US123',
  contacts: { ids: ['CT123'], lookupStatus: 'matched' },
  participants: { workspace: ['+15550000001'], external: ['+15550000002'], resolution: 'available' }, ...extra
});
const env = (id: string, type: string, resource: Record<string, unknown>, context: Record<string, unknown>) =>
  ({ id, apiVersion: '2026-03-30', createdAt: '2026-04-13T12:00:00.000Z', type, data: { resource, context, links: { quo: 'https://my.quo.com/inbox/...' } } });

export const OUR = '+15550000001';
export const THEM = '+15550000002';

export const SAMPLES = {
  messageReceived: env('EV1', 'message.received', { id: 'AC-message', direction: 'incoming', text: 'hello', media: [], status: 'received', createdAt: '2026-04-13T12:00:00.000Z' },
    { orgId: 'OR123', phoneNumberId: 'PN123', conversationId: 'CN123', userId: 'US123', contacts: { ids: ['CT123'], lookupStatus: 'matched' },
      senderIdentifier: THEM, recipientIdentifiers: [OUR] }),
  messageDelivered: env('EV2', 'message.delivered', { id: 'AC-message-out', direction: 'outgoing', text: 'hello', media: [], status: 'delivered', createdAt: '2026-04-13T12:00:00.000Z' },
    { orgId: 'OR123', phoneNumberId: 'PN123', conversationId: 'CN123', userId: 'US123', contacts: { ids: ['CT123'], lookupStatus: 'matched' },
      senderIdentifier: OUR, recipientIdentifiers: [THEM] }),
  messageFailed: env('EV3', 'message.failed', { id: 'AC-message-out', direction: 'outgoing', text: 'hello', status: 'failed', errorCode: '30006', createdAt: '2026-04-13T12:00:00.000Z' },
    { orgId: 'OR123', phoneNumberId: 'PN123', conversationId: 'CN123', userId: 'US123', senderIdentifier: OUR, recipientIdentifiers: [THEM] }),
  callRinging: env('EV4', 'call.ringing', { id: 'AC-call', direction: 'incoming', createdAt: '2026-04-13T12:00:00.000Z', updatedAt: '2026-04-13T12:00:00.000Z' },
    { orgId: 'OR123', phoneNumberId: 'PN123', conversationId: 'CN123', userId: 'US123', participants: { workspace: [OUR], external: [THEM], resolution: 'available' } }),
  callCompleted: env('EV5', 'call.completed', { id: 'AC-call', direction: 'incoming', status: 'answered', createdAt: '2026-04-13T11:59:55.000Z', answeredAt: '2026-04-13T12:00:00.000Z',
    completedAt: '2026-04-13T12:00:55.000Z', updatedAt: '2026-04-13T12:00:55.000Z', duration: 55, hasVoicemail: false }, ctx()),
  callMissed: env('EV6', 'call.missed', { id: 'AC-call-missed', createdAt: '2026-04-13T11:59:55.000Z', updatedAt: '2026-04-13T12:00:30.000Z' }, ctx()),
  callRecording: env('EV7', 'call.recording.completed', { id: 'AC-call', direction: 'incoming', createdAt: '2026-04-13T11:59:55.000Z', answeredAt: '2026-04-13T12:00:00.000Z',
    completedAt: '2026-04-13T12:00:55.000Z', updatedAt: '2026-04-13T12:01:05.000Z', duration: 55,
    recordings: [{ id: 'REabc123', duration: 55, startTime: '2026-04-13T12:00:00.000Z', type: 'audio/mpeg', url: 'https://recordings.example.com/REabc123.mp3' }] }, ctx()),
  callSummary: env('EV8', 'call.summary.completed', { callId: 'AC-call', processingStatus: 'completed', summary: ['Customer asked for pricing details.'], nextSteps: ['Send follow-up email.'],
    fromPhoneNumber: null, handledByAiAgent: false, answeredByUserId: null, jobs: [] }, ctx()),
  callTranscript: env('EV9', 'call.transcript.completed', { callId: 'AC-call', createdAt: '2026-04-13T12:00:01.000Z', duration: 42, processingStatus: 'completed',
    dialogue: [{ userId: 'US123', identifier: null, content: 'Thanks for calling, how can I help?', start: 0, end: 3 },
               { userId: null, identifier: THEM, content: 'Hi, I wanted to ask about pricing.', start: 3, end: 7 }] }, ctx()),
  callVoicemail: env('EV10', 'call.voicemail.completed', { id: 'AC-voicemail', voicemailId: 'VM123', callId: 'AC-call-missed', direction: 'incoming', duration: 18, from: THEM, to: OUR,
    transcript: 'Hi, leaving a quick message about the proposal...', recordingUrl: 'https://recordings.example.com/VM123.mp3', createdAt: '2026-04-13T12:01:00.000Z', updatedAt: '2026-04-13T12:01:10.000Z' }, ctx()),
  // legacy (v1 webhooks): data.object
  legacyMessage: { id: 'EVL1', object: 'event', apiVersion: 'v3', createdAt: '2022-01-24T19:22:25.427Z', type: 'message.received',
    data: { object: { id: 'AC-legacy-msg', object: 'message', from: THEM, to: [OUR], direction: 'incoming', body: 'Is the Civic free this weekend?', media: [], status: 'received',
      createdAt: '2022-01-24T19:22:25.427Z', userId: 'US123', phoneNumberId: 'PN123', conversationId: 'CN123' } } },
  legacyCallNoAnswer: { id: 'EVL2', object: 'event', apiVersion: 'v3', createdAt: '2022-01-24T19:30:55.400Z', type: 'call.completed',
    data: { object: { id: 'AC-legacy-call', object: 'call', from: THEM, to: OUR, direction: 'incoming', media: [], voicemail: { url: 'https://example.com/vm.mp3', type: 'audio/mpeg', duration: 7 },
      status: 'no-answer', createdAt: '2022-01-24T19:30:34.675Z', answeredAt: null, completedAt: '2022-01-24T19:30:55.000Z', userId: 'US123', phoneNumberId: 'PN123', conversationId: 'CN123' } } }
} as const;
