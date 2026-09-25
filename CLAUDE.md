# DiPo — working notes for Claude

## The palette is frozen

**Do not change any existing colour value. Ask first, every time.**

That covers:

- every token in `AppTheme` (`AppTheme.swift`) — surfaces, semantic colours, `onVividFill`, `accentTrack`, `voiceGlow`;
- every category hue in `TxCategory.iconBg` (`DataLayer.swift`).

These were settled deliberately — the emerald `#1DB87A` is DiPo's original green, kept over every alternative tried since, and the other hues were fitted around it in one lightness band so none of them looks heavier than it. Reasoning for each sits in the comments beside the values.

This applies no matter how a task is phrased. A redesign, a revamp, "make it match this reference", a contrast complaint, an accessibility pass — none of them is permission to edit a value here. Adding a *new* token for something that has no colour yet is fine; changing one that exists is not.

If a change genuinely looks necessary, say so and name it precisely — which token, from what to what, and why — then wait for an answer. `DiPoTests/PaletteLockTests.swift` pins every value, so an accidental edit fails that test.

**What is always fine without asking:** using an existing token in a new place, opacity or blend of a token at a call site, and choosing *which* token a new element should use.

## Other standing rules

- **Never boot the iOS Simulator.** Verify with headless `xcodebuild … build`. For visual work, render the geometry as HTML/SVG in the browser pane and look at it before writing Swift.
- **Do not commit** `DiPo.xcodeproj/project.pbxproj`, `DiPo.xcodeproj/xcshareddata/xcschemes/DiPo.xcscheme` or `DiPo/Info.plist` — those are Fahmi's working files.
- **New Swift files go in `DiPo/`.** That folder is a synchronised group, so files are picked up automatically; a file at the repo root has to be registered in the pbxproj by hand.
- **No `NSLocalizedString`.** There are no `.strings` files; every string goes through `loc()` and the tables in `LanguageManager.swift`, and both tables must stay in step.
- **When adding a `@Model`**, add it to the schema in `FinanceAppMain.swift` *and* to `BackupService` — export, both restore wipes, and both restore inserts. A backup that silently omits a feature is worse than one that fails.
