# Brain.app Icon — Neural Constellation (Liquid Glass)

Approved design from brainstorming session, 2026-07-20.

## Context

Brain.app (regular Dock app + menu-bar extra, `LSMinimumSystemVersion` 26.0, bundled by the Makefile — no Xcode project) has no app icon: no assets in the repo, no icon keys in `Resources/Info.plist`, so Dock/Finder show the generic blank app. Decisions locked with the user:

- **Concept:** neural constellation — luminous nodes and edges tracing a brain silhouette ("your knowledge, linked").
- **Palette:** electric cyan (nodes `#7BE8FF → #4FD6C4`, dim-teal edges `#2E7D8A`) on deep navy-black (`#0A1628 → #102A43`).
- **Pipeline:** true macOS 26 Liquid Glass `.icon` (Icon Composer format) compiled by `actool` in the Makefile — chosen over classic `.icns`.

## Artwork spec

- 1024×1024 canvas, macOS squircle grid, art inside ~80% safe area.
- ~12 nodes tracing a left-facing brain silhouette (cerebellum bump + brainstem notch) + 3–4 interior nodes; edges = silhouette segments plus a few interior cross-links. Three node radii for rhythm. Must read as a brain at 32 px.
- Layer stack: `.icon` background fill (navy, no bitmap) → `edges.png` → `nodes.png` (top layer gets Liquid Glass specular). Halo glows baked into the node art.

## Architecture

- `Resources/Icon/render-layers.swift` — CoreGraphics script (run with `swift`, no deps) that draws the layer PNGs; geometry as plain coordinate arrays.
- `Resources/Icon/Brain.icon/` — checked-in Icon Composer bundle (`icon.json` + layer assets); stays openable in Icon Composer.
- Makefile `icon` target: render layers → `xcrun actool … --app-icon Brain` → `Assets.car` copied into `Brain.app/Contents/Resources/`.
- `Resources/Info.plist` gains `CFBundleIconName` = `Brain`.

## Verification

- `qlmanage -t` thumbnails at 32/128/512 — silhouette must read at 32.
- Icon Composer: default/dark/clear/tinted variants look intentional.
- `make app && open Brain.app` → icon in Dock/app switcher/Get Info; `assetutil --info` lists icon entries.

## Fallbacks

If hand-authored `icon.json` won't compile: compose the same layers manually in Icon Composer (keep the actool Makefile step); worst case classic `.icns` + `CFBundleIconFile`.

## Out of scope

Menu-bar SF Symbol `brain` unchanged; no README/branding changes.
