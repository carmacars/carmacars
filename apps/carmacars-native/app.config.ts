import { existsSync } from 'node:fs';
import path from 'node:path';
import type { ExpoConfig } from 'expo/config';

// The CarmaCars app for iPhone and Android (release 48): native screens on the site's mobile API (/api/m/v1). The
// native projects are made from this file by `expo prebuild` in the build workflow (.github/workflows/apps-native.yml)
// and are never committed. docs/apps/native-publish.md lists what the owner sets up once.
//
// Values a build may set (all optional here, so `tsc` and the checks run without them):
//   APP_VERSION_NAME, APP_VERSION_CODE   the store version and the build number (the workflow's inputs)
//   APP_API_URL                          the site the app talks to (default https://carmacars.ca)
//   APP_APPLE_TEAM_ID                    the Apple Developer Team ID
//   GoogleService-Info.plist, google-services.json   written beside this file from GitHub secrets (never committed)
const SITE = 'carmacars.ca';
const APP_ID = 'ca.carmacars.app';
const version = /^\d+\.\d+\.\d+$/.test(process.env.APP_VERSION_NAME ?? '') ? process.env.APP_VERSION_NAME! : '1.0.0';
const build = /^\d{1,9}$/.test(process.env.APP_VERSION_CODE ?? '') ? Number(process.env.APP_VERSION_CODE) : 1;
const here = (f: string) => path.join(__dirname, f);
const iosFirebase = existsSync(here('GoogleService-Info.plist')) ? './GoogleService-Info.plist' : undefined;
const androidFirebase = existsSync(here('google-services.json')) ? './google-services.json' : undefined;
// the pages the app shows natively; any other page of the site opens in the in-app browser
const APP_LINK_PATHS = ['/cars', '/account', '/owner', '/staff', '/admin', '/app', '/sign-in'];
// the phone's location questions (store review reads these): what it is for, and never off duty
const LOC_IN_USE = 'CarmaCars uses your location to clock staff in and out at the car, to record where an agreement was signed, and to show you on the team\'s live map only while you are on shift or on a job, or around your pickup or return.';
const LOC_ALWAYS = 'CarmaCars staff keep sharing their location with the team\'s live map while on shift or on an active job, also with the app closed. It is never taken off duty, and you can turn it off in Profile, Location on the live map.';

const config: ExpoConfig = {
  name: 'CarmaCars',
  slug: 'carmacars',
  owner: undefined,
  scheme: 'carmacars',
  version,
  orientation: 'portrait',
  userInterfaceStyle: 'light',
  icon: './assets/icon.png',
  backgroundColor: '#ffffff',
  primaryColor: '#d0111b',
  ios: {
    bundleIdentifier: APP_ID,
    buildNumber: String(build),
    supportsTablet: false,
    appleTeamId: process.env.APP_APPLE_TEAM_ID || undefined,
    googleServicesFile: iosFirebase,
    // links to the site open the app; passwords and passkeys saved for the site work in the app
    associatedDomains: [`applinks:${SITE}`, `applinks:www.${SITE}`, `webcredentials:${SITE}`],
    infoPlist: {
      CFBundleDevelopmentRegion: 'en_CA',
      // export compliance: only the system's own encryption (HTTPS, the keychain), so no yearly report and no question at each upload
      ITSAppUsesNonExemptEncryption: false,
      NSCameraUsageDescription: 'CarmaCars uses the camera for your driver\'s licence, your selfie, and photos of the car at pickup and return.',
      NSPhotoLibraryUsageDescription: 'CarmaCars lets you choose a photo of your licence or of the car from your library.',
      NSLocationWhenInUseUsageDescription: LOC_IN_USE,
      // r48 (3350): staff on shift or on a job keep the live map current with the app closed (the phone shows its blue pill)
      NSLocationAlwaysAndWhenInUseUsageDescription: LOC_ALWAYS,
      NSFaceIDUsageDescription: 'Unlock CarmaCars with Face ID.',
      UIBackgroundModes: ['remote-notification', 'location'],
      LSApplicationQueriesSchemes: ['tel', 'sms', 'mailto']
    },
    // Apple's privacy manifest: no tracking; what the app collects and why; the system APIs it touches and the reasons
    privacyManifests: {
      NSPrivacyTracking: false,
      NSPrivacyTrackingDomains: [],
      NSPrivacyCollectedDataTypes: [
        ...['NSPrivacyCollectedDataTypeName', 'NSPrivacyCollectedDataTypeEmailAddress', 'NSPrivacyCollectedDataTypePhoneNumber', 'NSPrivacyCollectedDataTypePhysicalAddress',
          'NSPrivacyCollectedDataTypePhotosorVideos', 'NSPrivacyCollectedDataTypeSensitiveInfo', 'NSPrivacyCollectedDataTypeOtherUserContent', 'NSPrivacyCollectedDataTypeUserID',
          'NSPrivacyCollectedDataTypePurchaseHistory', 'NSPrivacyCollectedDataTypePaymentInfo', 'NSPrivacyCollectedDataTypePreciseLocation', 'NSPrivacyCollectedDataTypeDeviceID']
          .map((t) => ({ NSPrivacyCollectedDataType: t, NSPrivacyCollectedDataTypeLinked: true, NSPrivacyCollectedDataTypeTracking: false,
            NSPrivacyCollectedDataTypePurposes: ['NSPrivacyCollectedDataTypePurposeAppFunctionality'] }))
      ],
      NSPrivacyAccessedAPITypes: [
        { NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategoryUserDefaults', NSPrivacyAccessedAPITypeReasons: ['CA92.1'] },
        { NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategoryFileTimestamp', NSPrivacyAccessedAPITypeReasons: ['C617.1'] },
        { NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategorySystemBootTime', NSPrivacyAccessedAPITypeReasons: ['35F9.1'] },
        { NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategoryDiskSpace', NSPrivacyAccessedAPITypeReasons: ['E174.1'] }
      ]
    }
  },
  android: {
    package: APP_ID,
    versionCode: build,
    googleServicesFile: androidFirebase,
    adaptiveIcon: { foregroundImage: './assets/icon-foreground.png', backgroundImage: './assets/icon-background.png', backgroundColor: '#000000' },
    // r48 (3350): the live map; background location only for staff on shift or on a job, with the foreground-service notice
    permissions: ['CAMERA', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'ACCESS_BACKGROUND_LOCATION', 'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_LOCATION',
      'POST_NOTIFICATIONS', 'USE_BIOMETRIC', 'USE_FINGERPRINT', 'VIBRATE'],
    blockedPermissions: ['android.permission.RECORD_AUDIO', 'android.permission.READ_EXTERNAL_STORAGE', 'android.permission.WRITE_EXTERNAL_STORAGE', 'android.permission.SYSTEM_ALERT_WINDOW'],
    intentFilters: [{
      action: 'VIEW', autoVerify: true, category: ['BROWSABLE', 'DEFAULT'],
      data: [SITE, `www.${SITE}`].flatMap((host) => APP_LINK_PATHS.map((pathPrefix) => ({ scheme: 'https', host, pathPrefix })))
    }]
  },
  plugins: [
    'expo-router',
    ['expo-splash-screen', { image: './assets/splash-mark.png', imageWidth: 220, resizeMode: 'contain', backgroundColor: '#0a0a0a' }],
    'expo-secure-store',
    ['expo-local-authentication', { faceIDPermission: 'Unlock CarmaCars with Face ID.' }],
    ['expo-image-picker', { cameraPermission: 'CarmaCars uses the camera for your driver\'s licence, your selfie, and photos of the car at pickup and return.',
      photosPermission: 'CarmaCars lets you choose a photo of your licence or of the car from your library.', microphonePermission: false }],
    ['expo-location', { locationWhenInUsePermission: LOC_IN_USE,
      locationAlwaysAndWhenInUsePermission: LOC_ALWAYS, locationAlwaysPermission: LOC_ALWAYS,
      isIosBackgroundLocationEnabled: true, isAndroidBackgroundLocationEnabled: true, isAndroidForegroundServiceEnabled: true }],
    ['expo-notifications', { icon: './assets/notification/icon.png', color: '#d0111b', defaultChannel: 'alerts' }],
    // Firebase on iPhone needs static frameworks; both platforms build with the new architecture (React Native's default)
    ['expo-build-properties', { ios: { useFrameworks: 'static', deploymentTarget: '16.4' }, android: { minSdkVersion: 28 } }],
    ...(iosFirebase || androidFirebase ? ['@react-native-firebase/app', '@react-native-firebase/messaging'] : []),
    ['@stripe/stripe-react-native', { enableGooglePay: false }],
    './plugins/with-carmacars.js'
  ],
  experiments: { typedRoutes: false },
  extra: {
    apiUrl: (process.env.APP_API_URL || `https://${SITE}`).replace(/\/$/, ''),
    siteHosts: [SITE, `www.${SITE}`]
  }
};

export default config;
