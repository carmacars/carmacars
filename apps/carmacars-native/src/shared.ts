// What the app shares with the website, read straight from the site's source (one copy of each rule):
//   the mobile API's contract and its request shapes   web/src/features/mobile-api
//   one model name per car family ("C-Class", not "C300")   web/src/features/vin/model-family.ts
//   the angles of a check-in and the odometer, fuel and selfie reading   web/src/features/handover
//   notification preferences: the page's words and sums (r48)   web/src/features/notifications/prefs.ts
//   the live map: Location on the live map, its words and the good-fix rule (r48)   web/src/features/live-map/people.ts
// Those files import nothing, so the bundler (metro.config.js), TypeScript and the unit tests all read them as they are.
export * from '../../../web/src/features/mobile-api/contract.ts';
export { parse, ShapeError, type Shape } from '../../../web/src/features/mobile-api/shape.ts';
export { familyTree, modelFamily } from '../../../web/src/features/vin/model-family.ts';
export { ANGLES, angleLabel, anglesDone } from '../../../web/src/features/handover/angles.ts';
export { FUEL_EIGHTHS, emptyReading, fuelWords, readingPayload, readingPhotos, readingProblem, readingValues, selfieLive, type ReadingState } from '../../../web/src/features/handover/reading.ts';
export { applyChange, CADENCES, CHANNELS, channelNote, clockWords, summaryLine, type Cadence, type Channel, type PrefChange, type PrefState, type PrefType } from '../../../web/src/features/notifications/prefs.ts';
export { goodFix, REPORT_MS, STATE_MS, stateLine, type MyLocation } from '../../../web/src/features/live-map/people.ts';
