# Nevumi paid-launch setup

The public website may be published now. Paid sales are not enabled yet.
The currently linked v0.1.1 download is a free, unnotarized preview, not a timed
trial. The website labels the 14-day trial, $15 early access, and $25 standard
license as planned. No checkout, payment collection, license enforcement, or
trial-expiration logic is currently installed in the app.

## 1. Prepare a trusted installer

Enroll in the Apple Developer Program using your own Apple account:
https://developer.apple.com/programs/enroll/

After enrollment, create and install a **Developer ID Application** certificate
through Xcode / Apple Developer. An **Apple Development** certificate is not a
substitute for distribution. Configure a `notarytool` Keychain profile locally;
do not put Apple credentials in this repository or send them in chat.

The existing release script supports signing, notarization, and stapling:

```sh
SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
NOTARY_PROFILE='nevumi-notary' \
RELEASE_VERSION='0.2.0' RELEASE_BUILD='3' \
bash scripts/package-release.sh --public
```

Choose a final release version before running. The script refuses to overwrite
an existing installer and verifies the universal binary and signing/notary results.

## 2. Create the checkout

Create and activate your own Lemon Squeezy seller account:
https://docs.lemonsqueezy.com/help/getting-started/activate-your-store

Complete identity, bank/PayPal, business, and tax information directly with the
provider. Provider approval is required; publishing this website does not create
a seller account or authorize collecting money.

Suggested initial product settings, to review before accepting orders:

- Product: Nevumi Early Access
- Payment type: one-time, USD 15 (no subscription)
- Enable license-key generation
- Perpetual license duration for the purchased release
- Decide the allowed number of personal Macs before setting an activation limit
- Confirm refund policy, support contact, and which future updates are included
- Leave checkout in test mode until app activation has been tested end-to-end

Keep API keys, webhook signing secrets, and payout details out of the app binary,
website, GitHub, and chat. Public store/product IDs and the hosted checkout URL
can be supplied when wiring the integration.

## 3. Implement trial and licensing before advertising a working trial

Required app work:

- Record the first trial start securely in Keychain and calculate a 14-day period.
- Show days remaining and a native Buy / Activate License screen.
- After expiry, keep activation, purchase, and help available, and consistently
  restrict the paid features across the menu bar, notch, and global shortcuts.
- Activate, validate, and deactivate licenses through the provider's License API.
- Check the configured store/product identity on every accepted license response.
- Store activation state in Keychain, handle temporary network failures, and
  account for revoked licenses and refunds without deleting users' files.
- Test a valid purchase, an unrelated product key, activation limits, refunds,
  trial expiry, offline use, and changing/reinstalling the app.

Official integration documentation:
https://docs.lemonsqueezy.com/guides/tutorials/license-keys

## 4. Open paid sales

Only after the above is verified:

1. Upload the signed/notarized installer to a GitHub release.
2. Replace the preview download with the actual timed-trial build.
3. Add the live checkout URL and confirmed purchase terms to the website.
4. Replace “planned” and “sales open soon” labels with the working offer.
5. Publish the updated site and test a real checkout-to-activation journey.

A one-time purchase does not promise lifetime updates unless you explicitly
choose and publish that policy.

## Website hosting

`.openai/hosting.json` stores the Sites project identity and declares `dist/` as
the generated static directory. Preserve that ID for future website updates. The app source
remains on GitHub. Run `python3 scripts/website/build-static.py` to copy the
website from `docs/` into `dist/`. The Sites publishing checkout under `.build/` contains only
the website and hosting manifest. It is not the source of the app installer.
