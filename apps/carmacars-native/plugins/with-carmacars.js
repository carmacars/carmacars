// What the generated Android project needs beyond the Expo plugins: the phone's backups never carry the app's data (the
// session lives in the Keystore and must not move to another phone), no clear-text traffic, and the "can this phone
// call or text" question Android 11 and later only answers for declared intents.
const { withAndroidManifest } = require('expo/config-plugins');

module.exports = function withCarmaCars(config) {
  return withAndroidManifest(config, (c) => {
    const manifest = c.modResults.manifest;
    const app = manifest.application?.[0];
    if (app) {
      app.$['android:allowBackup'] = 'false';
      app.$['android:usesCleartextTraffic'] = 'false';
    }
    const want = [['android.intent.action.DIAL', 'tel'], ['android.intent.action.SENDTO', 'smsto'], ['android.intent.action.SENDTO', 'mailto']];
    const queries = (manifest.queries ??= [{}]);
    const q = queries[0];
    q.intent = [...(q.intent ?? []), ...want.map(([action, scheme]) => ({ action: [{ $: { 'android:name': action } }], data: [{ $: { 'android:scheme': scheme } }] }))];
    return c;
  });
};
