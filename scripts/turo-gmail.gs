// CarmaCars: Turo emails from rent@carmacars.ca's Gmail to the website (Turo by email, migration 0063).
// Paste into script.google.com (signed in as rent@carmacars.ca), put the token in TOKEN, then Run "setup" once.
// Every 5 minutes it sends each new email from turo.com, as received, to carmacars.ca, which reads the trip and blocks
// the car's calendar. Each email is sent once (its id is remembered). Nothing in Gmail is changed or deleted.
const ENDPOINT = 'https://carmacars.ca/api/inbound/turo';
const TOKEN = 'PASTE_TOKEN_HERE';
const MAILBOX = 'rent@carmacars.ca';

function setup() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'syncTuro') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('syncTuro').timeBased().everyMinutes(5).create();
  sync_('from:turo.com newer_than:30d'); // the first run also sends the last 30 days of Turo emails
}

function syncTuro() { sync_('from:turo.com newer_than:3d'); }

function sync_(query) {
  const props = PropertiesService.getScriptProperties();
  const seen = JSON.parse(props.getProperty('seen') || '[]');
  const done = {};
  seen.forEach(function (id) { done[id] = true; });
  const threads = GmailApp.search(query, 0, 100);
  threads.forEach(function (thread) {
    thread.getMessages().forEach(function (msg) {
      const id = msg.getId();
      if (done[id] || !/turo\.com/i.test(msg.getFrom())) return;
      const res = UrlFetchApp.fetch(ENDPOINT, {
        method: 'post', contentType: 'message/rfc822', payload: msg.getRawContent(), muteHttpExceptions: true,
        headers: { Authorization: 'Bearer ' + TOKEN, 'x-envelope-from': MAILBOX }
      });
      if (res.getResponseCode() === 200) { done[id] = true; seen.push(id); }
      else console.warn('CarmaCars answered ' + res.getResponseCode() + ' for ' + msg.getSubject());
    });
  });
  props.setProperty('seen', JSON.stringify(seen.slice(-2000)));
}
