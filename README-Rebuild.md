# FlashKit iOS — rebuild package

This package contains replacement source/configuration files for the `MuntazirFX/flash-kit` repository.

## Files to replace

- `Sources/App.swift` — rewritten app: local/offline library, `.swf` import validation, in-app web archive explorer, direct SWF downloader, player overlay, saved preferences, and basic GameController mapping.
- `www/index.html` — Ruffle player startup/error handling and a render-FPS counter.
- `project.yml` — tracked XcodeGen project specification.
- `.github/workflows/build.yml` — CI build and unsigned IPA artifact workflow.

**Keep the existing `www/ruffle.js`, Ruffle `.wasm` files, and any other bundled Ruffle runtime assets.** This package intentionally does not include those large third-party runtime files.

## Apply the replacement

1. Download and extract `FlashKit-Rebuild.zip`.
2. Copy the included files into the root of your existing repository, replacing files with the same paths.
3. Keep the current `www/ruffle.js` and `.wasm` files in place.
4. Commit and push to GitHub. Open **Actions → Build FlashKit IPA** and download the `FlashKit-iOS-build` artifact.
5. Test the IPA on a real iPhone using your normal signing/sideloading workflow.

## Feature notes and limits

- My Library stores validated SWF files in the app's Documents/Games directory, so already-imported games can be launched offline.
- The plus button imports `.swf` files through the iOS Files picker.
- Archive Explorer is a WKWebView browser. Tapping a direct link whose URL ends in `.swf`, or pasting a direct `.swf` URL, starts a download. The response must be HTTP-successful and the file must begin with a valid SWF signature (`FWS`, `CWS`, or `ZWS`) before it is added to the library.
- A site that requires authentication, blocks downloads, hides SWF files behind scripts, or serves a non-SWF page cannot be guaranteed to download.
- The bundled player is Ruffle. The alternate-engine setting is a placeholder, not a second engine; WaFlash must be separately integrated and licensed/packaged before it can be offered.
- The displayed FPS is browser render FPS, not guaranteed SWF simulation FPS. Ruffle's public web API does not expose a universal hard FPS cap, so the 30/40/50 setting is saved but does not currently enforce a cap.
- Touch controls send keyboard events to the Ruffle player; some games use mouse input, custom key mappings, or unsupported Flash APIs and may need game-specific work.
- GameController support maps basic controller buttons and D-pad to keyboard keys. It is not a full 25-binding editor and should be tested with each controller model.
- The workflow creates an **unsigned** IPA. It does not sign the app or bypass Apple signing requirements.
