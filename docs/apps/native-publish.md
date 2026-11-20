# Publishing the native CarmaCars app: the owner's steps

Release 48. The app is `apps/carmacars-native`: native screens (Expo and React Native) on the site's mobile API
(`/api/m/v1`). It replaces the first app (`apps/carmacars`, a shell around the website), which was never submitted.
What is left needs the company's identity, its accounts and its keys, so only you can do it. Do the steps in order; each
says where its result goes. Nothing here goes into the code: keys and files go into GitHub's secrets or the Supabase
vault, never the repository.

If you already did a step for the first app, it still counts: the bundle id (`ca.carmacars.app`), the secret names and
the Firebase project are the same. Skip to step 7.

| What | Cost | Time |
| --- | --- | --- |
| D-U-N-S number for 18122211 Canada Inc. | Free | Up to 5 business days (sometimes 14) |
| Apple Developer Program, as an organization | US$99 a year | 1 to 3 days after the D-U-N-S number |
| Google Play Console, as an organization | US$25 once | A few days (identity check) |
| Firebase project (phone alerts) | Free | 15 minutes |
| Builds (GitHub Actions, no paid build service) | Free on a public repository | About 40 minutes a build |
| Apple review, Google review | Free | Apple 1 to 3 days; Google's first review up to 7 days |

Apple shows the legal name of the company that enrolls as the app's seller, so the App Store will show **18122211 Canada
Inc.** under the app (Apple does not accept a trade name there). Google Play shows the developer name you type, so it can
say **CarmaCars**.

## 1. D-U-N-S number

1. Open Apple's lookup: https://developer.apple.com/enroll/duns-lookup/ and search for 18122211 Canada Inc. at the
   company's mailing address.
2. Found: note the 9-digit number. Not found: press **Submit** on the same page; Dun & Bradstreet emails the number.
3. Use the same legal name and address everywhere below, exactly as D&B has them. A different spelling is the most
   common reason Apple's enrolment stalls.

## 2. Apple Developer account (US$99 a year)

1. Sign in at https://developer.apple.com/programs/enroll/ with an Apple Account made for the company
   (rent@carmacars.ca, two-factor authentication on). Choose **Organization**.
2. Enter the legal entity name, the D-U-N-S number, carmacars.ca as the website, and yourself as the person with legal
   authority (Director). Apple may call you to confirm. Pay the US$99.
3. Once approved: https://developer.apple.com/account, **Membership details**: copy the **Team ID** (10 letters and
   numbers). It goes into GitHub as the variable `APP_APPLE_TEAM_ID` (step 6).
4. **Certificates, Identifiers & Profiles**, **Identifiers**, **+**, **App IDs**, **App**: description `CarmaCars`,
   Bundle ID **Explicit** `ca.carmacars.app`. Tick **Associated Domains** and **Push Notifications**. **Register**.
   (Associated Domains is what lets links to carmacars.ca open the app and lets passkeys work.)
5. **Keys**, **+**: name `CarmaCars push`, tick **Apple Push Notifications service (APNs)**, **Configure**: **Sandbox &
   Production**. **Register**, then **Download** the `.p8` file (only once) and note its **Key ID**. It goes to Firebase
   (step 4). Keep the file in your password manager.
6. https://appstoreconnect.apple.com, **Apps**, **+**, **New App**: iOS, name `CarmaCars`, primary language **English
   (Canada)**, bundle ID `ca.carmacars.app`, SKU `carmacars-ios`, **Full Access**.
7. **Users and Access**, **Integrations**, **App Store Connect API**, **Team Keys**, **+**: name `GitHub builds`, access
   **Admin** (Admin lets the build make its own signing certificate, so there is nothing else to sign). **Download** the
   `.p8` (only once), and copy the **Key ID** and the **Issuer ID** shown above the list. All three go into GitHub
   (step 6).

## 3. Google Play Console (US$25 once)

1. https://play.google.com/console/signup with the company Google account (rent@carmacars.ca). Choose
   **An organization**; enter the D-U-N-S number, developer name `CarmaCars`, contact email contact@carmacars.ca,
   website https://carmacars.ca and the public phone. Google checks your identity as the company's representative (photo
   ID). Pay the US$25.
2. **Create app**: name `CarmaCars`, default language **English (Canada), en-CA**, **App**, **Free**, accept the
   declarations.
3. The very first build is uploaded by hand (step 7). Then **Test and release**, **App integrity**, **App signing**:
   copy the **SHA-256 certificate fingerprint** of the **App signing key** and of the **Upload key**. Both go into GitHub
   as the variable `APP_ANDROID_CERT_SHA256`, separated by a comma (step 6). They let links to carmacars.ca open the app
   and let passkeys work on Android.
4. Optional, so later builds upload themselves: https://console.cloud.google.com, the project Play made (or any),
   **IAM & Admin**, **Service accounts**, **Create**, name `play-uploads`, no roles; **Keys**, **Add key**, **JSON**. In
   Play Console, **Users and permissions**, **Invite new users**, the service account's email, app permission
   **Release to testing tracks** for CarmaCars. The JSON file's whole text is the GitHub secret
   `PLAY_SERVICE_ACCOUNT_JSON` (step 6). Without it, each Android build waits as a file for you to upload.

## 4. Firebase (phone alerts, free)

1. https://console.firebase.google.com with the company Google account, **Create a project**, name `CarmaCars`. Google
   Analytics: **off** (not needed, and it would add tracking to the privacy labels).
2. **Add app**, **Android**: package `ca.carmacars.app`, nickname `CarmaCars Android`. Download
   `google-services.json`. Skip the SDK steps (the app has them).
3. **Add app**, **Apple**: bundle ID `ca.carmacars.app`, nickname `CarmaCars iOS`. Download
   `GoogleService-Info.plist`. Skip the SDK steps.
4. **Project settings**, **Cloud Messaging**, **Apple app configuration**, **APNs Authentication Key**, **Upload**: the
   `.p8` from step 2.5, its Key ID, and the Team ID.
5. **Project settings**, **Service accounts**, **Generate new private key**: a JSON file. This is the key the site
   sends alerts with. Add its whole text to the Supabase vault as `deploy_fcm_service_account` (step 6). Keep the file
   in your password manager and delete the download.

## 5. Android upload key (it never goes into the code)

You said yes to having the key made for you. It was not made in this release: making it is only useful together with
putting it into GitHub's secrets, and the build helper has no access to them. It takes two minutes on your Mac (Java's
`keytool` comes with Android Studio, or `brew install openjdk`):

```
keytool -genkeypair -v -keystore carmacars-upload.jks -alias carmacars-upload -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=CarmaCars, O=18122211 Canada Inc., L=Toronto, ST=Ontario, C=CA"
```

It asks for a password twice: use a long one and save it, with the `.jks` file, in your password manager. Google signs
the published app with its own key (Play App Signing); this one only proves uploads come from you. If it is ever lost,
Google can reset it from Play Console, **App integrity**.

If you would rather not use a terminal: ask Claude, in a session on your laptop, to run the command and paste the four
values into GitHub with you (a session with GitHub secret access can do the whole of step 6).

## 6. Where each secret goes

Files are added as base64 text. On a Mac: `base64 -i <file> | pbcopy` copies it (then paste). On Windows PowerShell:
`[Convert]::ToBase64String([IO.File]::ReadAllBytes("<file>")) | Set-Clipboard`.

**GitHub**, repository carmacars/carmacars, **Settings**, **Secrets and variables**, **Actions**. Variables are on the
**Variables** tab, secrets on the **Secrets** tab; press **New repository variable** or **New repository secret** for
each:

| Name | Kind | Value |
| --- | --- | --- |
| `APP_APPLE_TEAM_ID` | Variable | The Team ID (step 2.3) |
| `APP_ANDROID_CERT_SHA256` | Variable | The two SHA-256 fingerprints, comma separated (step 3.3) |
| `ASC_KEY_ID` | Secret | The App Store Connect API key's Key ID (step 2.7) |
| `ASC_ISSUER_ID` | Secret | Its Issuer ID (step 2.7) |
| `ASC_KEY_P8` | Secret | The whole text of its `.p8` file (open it in TextEdit) |
| `FIREBASE_IOS_PLIST_B64` | Secret | `GoogleService-Info.plist` in base64 (step 4.3) |
| `FIREBASE_ANDROID_JSON_B64` | Secret | `google-services.json` in base64 (step 4.2) |
| `ANDROID_UPLOAD_KEYSTORE_B64` | Secret | `carmacars-upload.jks` in base64 (step 5) |
| `ANDROID_KEYSTORE_PASSWORD` | Secret | Its password |
| `ANDROID_KEY_ALIAS` | Secret | `carmacars-upload` |
| `ANDROID_KEY_PASSWORD` | Secret | The same password |
| `PLAY_SERVICE_ACCOUNT_JSON` | Secret, optional | The Play uploads service account JSON (step 3.4) |

**Supabase**, the carmacars project, **Project settings**, **Vault**, **Add new secret** (or in the SQL editor:
`select vault.create_secret('<paste the JSON>', 'deploy_fcm_service_account');`):

| Name | Value |
| --- | --- |
| `deploy_fcm_service_account` | The Firebase service account JSON (step 4.5) |

Then run a deploy of the site (Actions, **ci**, **Run workflow**, deploy on). It turns alerts on for the app and serves
`carmacars.ca/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json` (the files that let email and
text links open the app, and that tie passkeys to the app). Run it again after you add `APP_ANDROID_CERT_SHA256` in
step 3.3.

## 7. Build, test, publish

1. Actions, **apps-native**, **Run workflow**: platform `both`, version `1.0.0`, upload on, listing off. About 40
   minutes. A platform whose secrets are missing is skipped with a note at the top of the run.
2. iPhone: the build appears in App Store Connect, **TestFlight**, after about 15 minutes of processing. Add yourself and
   Mahad as internal testers and install TestFlight on your phones.
3. Android, the first time: download the `.aab` from the run's **Artifacts**. Play Console, **Test and release**,
   **Testing**, **Internal testing**, **Create new release**, upload it, add yourself and Mahad as testers, roll out.
   Then do step 3.3 and the site deploy. Later builds upload themselves if `PLAY_SERVICE_ACCOUNT_JSON` is set.
4. Try on both phones, with a renter account and a staff account:
   - Sign in with email, with a texted code, and (Profile, **Passkeys**, **Add a passkey on this phone**) with a passkey.
   - Profile, **Alerts on this phone**, then **Send a test alert**; tap the alert.
   - Profile, **App lock** on; leave the app for 5 minutes; Face ID or the fingerprint opens it.
   - Find a car, choose dates, **Request to book**; accept the offer; sign the agreement; pay with a card; take the
     licence photos and the selfie; check in at the car; send a message; ask to extend.
   - Field staff: clock in (it asks for the location once), open a job, take a photo, clock out.
   - Sales: claim a lead, press **Call** (your own phone rings first, from the CarmaCars number), send a text.
   - A link from a CarmaCars email opens the app; airplane mode shows the black "No connection" bar; Profile shows
     **Delete my account**.
5. Fill the listings. The texts and graphics are in `apps/carmacars/store` (docs/apps/store-listing.md has the privacy
   answers, the age rating, the screenshots plan and the review notes). Run **apps-native** again with listing on to
   send the texts, or paste them. Take the screenshots from the phones in step 4. In the review notes give Apple and
   Google a renter sign-in to test with, and say that account deletion is in Profile, **Delete my account**.
6. **Submit for review** in App Store Connect and **Send for review** (Production) in Play Console.

Two answers in the privacy forms changed with this app: **Precise location** is also collected when field staff clock
in and out, and **Photos** now come from the phone's own camera. Both are "used for app functionality, linked to the
person, not used for tracking", as the app's privacy manifest says.

A new store build is needed whenever the app's own screens change. Run **apps-native** again with a higher version; the
site's own releases do not reach the app's screens by themselves, only its data and its rules.
