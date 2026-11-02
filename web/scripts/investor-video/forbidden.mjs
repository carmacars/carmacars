// The investor video (docs/investor-video/script.md): what it may never show or say, on any slide or in any line. The
// owner, r27: no fleet size, utilization, insurance premium or internal costs. build.mjs checks the narration, the
// captions and every slide's text, and refuses a script token named for one of them; the unit test
// src/features/deck/video-forbidden.test.ts holds the cases. An owner's fee tier ("1 to 2 cars") is that owner's own
// cars, not the fleet.
export const FORBIDDEN = [
  [/\bfleet (?:size|of \d)|(?<!\bto )\b\d[\d,]*\s+(?:cars|vehicles)\b(?! (?:a|per) )|\bcars? (?:on the road|in (?:the|our) fleet):?\s*\d/i, 'fleet size or car count'],
  [/\butili[sz](?:ation|ed)\b|\boccupancy\b|\bbooked (?:\d+%|days? a month)/i, 'utilization'],
  [/\binsurance premiums?\b|\bpremiums? (?:we|CarmaCars) pay|\bpolicy (?:costs?|premium)/i, 'insurance premium'],
  [/\b(?:our|internal|operating) costs?\b|\bcost (?:per|of each) (?:car|vehicle|rental)|\bmargins?\b|\bburn rate\b/i, 'internal costs']
];
export const FORBIDDEN_TOKEN = /fleet|cars?_?count|utili|premium|cost|margin/i;
export function forbidden(text, where) {
  return FORBIDDEN.filter(([re]) => re.test(text)).map(([re, what]) => `${where}: ${what} ("${text.match(re)[0]}"): never in the video`);
}

