# Website UI screenshots

`ScreenshotMain.swift` renders the current production SwiftUI views with sample
state. It does not reconstruct the interface in HTML or load personal data.
The app sources are copied to a disposable Xcode target, where view visibility
and fixture setters are exposed. Production app files are never edited.

Requirements: Xcode 26+, XcodeGen, and resolved packages under
`.build/Nevumi/SourcePackages/checkouts` (build the app once with
`-derivedDataPath .build/Nevumi` if needed).

From the repository root:

```sh
python3 scripts/website/render-screenshots.py
```

The command updates the PNGs in `docs/screenshots/`. Inspect the output after
changes to app views. Source track names, lyrics, calendar entries, documents,
and the image attachment are fixtures; no Spotify connection, AI request,
calendar save, or screen recording is performed. The renderer has its own
bundle identifier and does not read Nevumi's saved conversation history.

Website screenshots can be opened at full size using the image viewer or a
normal link when JavaScript is disabled.

`WindowSwitching.swift` also renders two native AppKit sample document windows
for the website's focus-switching demonstration. The website's Active label and
outline are explanatory annotations; Nevumi switches focus without adding an
overlay or moving the actual windows.
