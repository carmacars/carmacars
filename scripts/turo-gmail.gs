// CarmaCars: Turo emails from rent@carmacars.ca's Gmail to the website (Turo by email, migration 0063).
// Paste into script.google.com (signed in as rent@carmacars.ca), put the token in TOKEN, then Run "setup" once.
// Every 5 minutes it sends each new email from turo.com, as received, to carmacars.ca, which reads the trip and blocks
// the car's calendar. Each email is sent once (its id is remembered). Nothing in Gmail is changed or deleted.
// R51 (5204): bounce emails (mailer-daemon, postmaster: emails that an insurer's server refused) go to /api/inbound/bounce
// the same way, so the site marks the send failed and tells an Admin. After updating, Run "setup" once again.
const ENDPOINT = 'https://carmacars.ca/api/inbound/turo';
const BOUNCES = 'https://carmacars.ca/api/inbound/bounce';
const TOKEN = 'PASTE_TOKEN_HERE';
const MAILBOX = 'rent@carmacars.ca';

function setup() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'syncTuro') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('syncTuro').timeBased().everyMinutes(5).create();
  sync_('from:turo.com newer_than:30d'); // the first run also sends the last 30 days of Turo emails
}

function syncTuro() {
  sync_('from:turo.com newer_than:3d');
  sync_('from:(mailer-daemon OR postmaster) newer_than:3d', BOUNCES, /mailer-daemon|postmaster/i);
}

function sync_(query, endpoint, fromRe) {
  endpoint = endpoint || ENDPOINT;
  fromRe = fromRe || /turo\.com/i;
  const props = PropertiesService.getScriptProperties();
  const seen = JSON.parse(props.getProperty('seen') || '[]');
  const done = {};
  seen.forEach(function (id) { done[id] = true; });
  const threads = GmailApp.search(query, 0, 100);
  threads.forEach(function (thread) {
    thread.getMessages().forEach(function (msg) {
      const id = msg.getId();
      if (done[id] || !fromRe.test(msg.getFrom())) return;
      const res = UrlFetchApp.fetch(endpoint, {
        method: 'post', contentType: 'message/rfc822', payload: msg.getRawContent(), muteHttpExceptions: true,
        headers: { Authorization: 'Bearer ' + TOKEN, 'x-envelope-from': MAILBOX }
      });
      if (res.getResponseCode() === 200) { done[id] = true; seen.push(id); }
      else console.warn('CarmaCars answered ' + res.getResponseCode() + ' for ' + msg.getSubject());
    });
  });
  props.setProperty('seen', JSON.stringify(seen.slice(-2000)));
}
