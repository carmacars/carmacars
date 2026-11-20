// The bundler also reads three folders of the website (the mobile API's contract and two pure rule files, re-exported
// by src/shared.ts), so the app and the site share one copy of each. Those files import nothing from packages; anything
// they might need later is looked up in this app's node_modules, never in web/.
const path = require('node:path');
const { getDefaultConfig } = require('expo/metro-config');

const web = path.resolve(__dirname, '../../web/src/features');
const config = getDefaultConfig(__dirname);
config.watchFolders = [...(config.watchFolders ?? []), ...['mobile-api', 'vin', 'handover'].map((d) => path.join(web, d))];
config.resolver.nodeModulesPaths = [path.resolve(__dirname, 'node_modules')];
module.exports = config;
