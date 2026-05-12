# SmarterPaw Social Image Tool — Claude Code Handoff

Single-file HTML canvas-based social media image generator for SmarterPaw LLC (Meowijuana, Doggijuana, Kitty Ka-Zoom). Currently **v111**.

**Repo:** `SmarterPaw-LLC/social-media-image-maker`
**Hosted:** `https://smarterpaw-llc.github.io/social-media-image-maker/`
**Working file:** `index.html` (~1.8 MB, ~7,700 lines, single self-contained HTML)
**Architecture:** Plain JS (no build step, no framework). One `<style>` tag, two `<script>` tags (the second is the main one), one HTML body.

The tool was entirely client-side through v111 (IndexedDB + downloadable JSON files). **This repo adds Supabase cloud-sync** as a new layer — see the Supabase section below. IDB stays as the fast local cache.

---

## Working with this codebase

### Read this first
1. **Surgical edits, not rewrites.** Use targeted `Edit` against unique snippets. Never rewrite a whole function unless asked.
2. **Version bump on every shippable change.** Version string lives near the top of `<body>`: `<span>SmarterPaw Marketing · v111</span>`. Bump on every change that ships.
3. **Syntax-check before shipping.** After edits, extract the inline script and run through Node:
   ```bash
   python3 -c "import re; html=open('index.html').read(); scripts=re.findall(r'<script[^>]*>(.*?)</script>', html, re.DOTALL); open('/tmp/tool.js','w').write(scripts[1])"
   node --check /tmp/tool.js && echo OK
   ```
   There are **two** `<script>` blocks; `scripts[1]` is the main one (`scripts[0]` is empty or a tiny loader).
4. **No new dependencies beyond what's embedded.** Everything ships in the single HTML file. Only external runtime fetches are Shopify-hosted brand images and Google Fonts CSS. (Supabase JS via CDN is the one planned exception — see Supabase section.)

### Workflow for any change
1. Read the relevant code with `Read` / `Grep` before editing.
2. Make surgical `Edit` against the snippet.
3. Bump the version: replace `Marketing · v111` → `Marketing · v112`.
4. Run the Node syntax check above.
5. Commit with a one-line message naming the version + summary.

### Comment style
Comments are conversational, explain **why** rather than what, often note historical context (e.g., "v97 added overscan; v110 made setCanvasSize the entry point so board switches honor it"). Match this style.

---

## Architecture

### Per-board state via window getter/setter trickery (line ~886)
```js
var boards = [];          // array of {id, name, layers, canvasW, canvasH, ...}
var currentBoardId = 1;

(function defineBoardAccessors(){
  var fields = ['layers','canvasW','canvasH','selectedId','selectedIds',
                'undoStack','redoStack','activePresetId'];
  fields.forEach(function(f){
    Object.defineProperty(window, f, {
      configurable: true,
      get: function(){ return getBoard()[f]; },
      set: function(v){ getBoard()[f] = v; }
    });
  });
})();
```
The rest of the code uses `layers`, `canvasW`, `selectedId`, etc. as if they were globals, but they read/write the **currently active board's** state. New code should follow this convention. To switch boards, call `switchBoard(boardId)`.

### Layer types
Layers are plain objects pushed into `layers`. Common fields: `id, type, name, x, y, w, h, rotation, opacity, hidden, locked`.

| `type` | Purpose | Key fields |
|--------|---------|------------|
| `image` | Uploaded photo | `img` (HTMLImageElement), `src`, `fit`, `flipH/V`, `cropX/Y/W/H`, `_baseW/H` |
| `framedImage` | Photo inside decorative frame | `_img`, `_imgSrc`, `frameStyle`, plus image-fill props |
| `text` | Editable text with effects | `text`, `font`, `size`, `color`, `align`, `lineHeight`, shadow/stroke/outline/gradient effects |
| `sticker` | Multi-line stylized text | uses `scale` (not `w/h`), `lines[]` for per-line styling |
| `shape` | Rectangle, circle, polygon | `shape`, `fillColor`, `strokeColor`, `strokeWidth` |
| `sprinkle` | Procedurally-placed catnip pieces | `pieces[]`, `density`, `bgRemove` |
| `svg` | Loaded SVG | `img`, `svgText` (source of truth), `url` (blob URL), `natW/H`, `flipH/V` |
| `video` | MP4/WebM video | `_video` (HTMLVideoElement), `videoSrc`, `trimStart/End` |

### Serialization (two flavors)
- **`serializeLayers()`** (line ~1265) — **full** serialization for persistent storage (autosave, file save, cloud sync). Includes image base64 (`_imgSrc`), video URLs, SVG text.
- **`serializeForUndo()`** (line ~1295) — **lightweight** serialization for undo/redo. Omits image src, video src, SVG text — those are re-attached from live in-memory layers on restore. Critical for memory pressure (v111 fix).

Deserializer consults the current `layers` array by id and copies live image/video references when a snapshot omits src data. Undo snapshots are now KB instead of MB.

### Canvas drawing
`redraw()` (line ~5300) is the master draw:
1. Clear canvas (may be larger than export bounds if overscan is on)
2. Fill overscan margin grey if applicable
3. Translate by `(overscanPx, overscanPx)` so layer `(0,0)` is top-left of export area
4. Checkerboard background in the export region
5. Iterate layers in order, calling `draw<Type>Layer(ctx, layer)`
6. Selection chrome (bounding box, resize/rotate handles)
7. Marquee rectangle if dragging
8. Crop overlay if in crop mode
9. Overscan visual markers (dim overlay + export-bounds border) if overscan is on

**`redrawSoon()`** is rAF-throttled — use from drag/resize/rotate/marquee handlers. Direct `redraw()` is fine for selection changes, panel updates.

### Coordinate spaces
- **Layer coords** — numeric `x/y` in canvas pixels; `(0,0)` is top-left of export area. Can be negative (off to the left/top) or > canvasW/H (off the right/bottom).
- **Canvas-pixel coords** — same as layer coords, but offset by overscan when drawing.
- **Client coords** — from mouse events. Convert via `clientToCanvas(clientX, clientY)`: subtracts `wrap.left`, divides by `zoomLevel`, subtracts overscan.
- **Local (layer-rotated) coords** — when a layer is rotated, hit-test rotates click coords around the layer's center by `-rotation` against the unrotated bounding box. Same trick for resize math to convert mouse delta into the layer's local axes (v103 fix for 180°-rotated layers growing on inward drag).

### Overscan
Toggle at bottom-right (⤢ button) expands canvas viewport by 300px on each side, revealing layers positioned outside export bounds. Internals:
- `_overscanOn` (bool), `_overscanPx = 300`
- `setCanvasSize(w, h)` sizes canvas to `(w + 2*overscan, h + 2*overscan)` and triggers redraw
- `applyZoom` scales the wrap div CSS to overscan-expanded size
- `redraw` translates by overscan before drawing
- Hit-test sites subtract overscan from click coords (five sites: `clientToCanvas` + four inline `wrap.getBoundingClientRect()` in mousedown/mousemove)
- **Export is unaffected** — `outCanvas` is always `(canvasW, canvasH)`; out-of-bounds layers get clipped by canvas pixel boundary
- `ensureChromeVisible()` auto-enables overscan when a selected layer's chrome extends outside canvas. One-way: never auto-disables.

### Embedded assets
- **`MEOWIJUANA_FONT_DATA`** — Cooper-Black-style brand font, WOFF2 base64
- **`CATNIP_PHOTO_FONT_DATA`** — ~951 KB CBDT/CBLC OpenType bitmap font built from photographed catnip-piece letters. 40 glyphs.
- **`CATNIP_PIECE_DATA_URLS`** — 5 WebP catnip pieces for sprinkle layer
- **`EMOJI_CURATED`** — 134 hand-picked SmarterPaw favorites
- **`EMOJI_GROUPS`** — 1,914 emojis across 9 Unicode categories. Source: `muan/unicode-emoji-json` (MIT).

### Brand assets (loaded from Shopify CDN at runtime)
```
Meowijuana logo:  https://cdn.shopify.com/s/files/1/0657/0831/files/Meowijuana_Logo_social.png?v=1776974640
Doggijuana logo:  https://cdn.shopify.com/s/files/1/0657/0831/files/Doggijuana_Logo-social.png?v=1776974656
Kitty Ka-Zoom:    https://cdn.shopify.com/s/files/1/0634/2796/9198/files/Kitty_Ka-Zoom_Logo_social.png?v=1776974760
Cooper Black:     https://cdn.shopify.com/s/files/1/0657/0831/files/CooperBlack-Std.otf
```
URLs are version-pinned. If a logo updates, the `?v=` query string changes — update the URL in source.

---

## Supabase

**Dedicated project** for this app (separate from forecast). Free tier — 2nd of 2 free projects under the SmarterPaw-LLC org. Auto-pauses after 7 days of inactivity; restored manually from the Supabase dashboard.

- URL: `TBD — fill in after creating project (Settings → API → Project URL)`
- Anon key: `TBD — fill in after creating project (Settings → API → anon public)`
- Sign-in: separate from the forecast project. Add user via Authentication → Users → Add user.

### Database tables
- **user_profiles** — per-user meta (email, full_name, role). Auto-created on signup via `handle_new_user()` trigger.
- **audit_log** — who-did-what trail. Writes via `log_action(action, details)` RPC.
- **social_designs** — cloud-synced designs (mirror of IDB).
  - `id` bigserial PK, `user_id` uuid (auth.users), `name` text
  - `brand` text ('meowi' | 'kkz'), `canvas_w` int, `canvas_h` int
  - `schema_version` int, `app_version` text
  - `state` jsonb — full `gatherDesignState()` payload (layers + meta), same shape as the `.spdesign.json` file
  - `thumbnail` text (optional data URI), `is_autosave` bool
  - `created_at`, `updated_at` (auto-touched)
  - RLS: each user reads/writes their own rows only (`auth.uid() = user_id`)
  - Unique partial index: one autosave row per user (`where is_autosave = true`)

### Setup — run on a fresh Supabase project, in order
1. `supabase_auth_setup.sql` — user_profiles, audit_log, log_action RPC, role grants. Verify: `select count(*) from user_profiles;` matches auth.users count.
2. `supabase_social_designs_setup.sql` — the designs table. Verify: `select count(*) from public.social_designs;` (0 on fresh install).

Both are idempotent (`create ... if not exists`, `drop policy if exists`) — safe to re-run.

### TODO — wire Supabase into index.html
Not yet wired (v111 is pre-cloud). Plan mirrors the forecast project's v4.100 saved-views migration:
1. Add `<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>` to `<head>` (the one new external CDN dep, blessed exception to the "no new deps" rule).
2. Init `var sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY)`.
3. Gate the editor behind email/password sign-in (or magic link). Stay-signed-in via the client's localStorage session.
4. On save (`confirmSaveDesign`): write to `social_designs` (insert if `_currentDesignId` null + no cloud id, update otherwise); keep the IDB write as fast local cache; file download stays as portable export.
5. On load (`renderMyDesigns`): pull `social_designs` rows for signed-in user, merge with IDB-only rows in the grid.
6. Autosave: upsert into the single autosave row per user (partial unique index makes upsert clean).
7. Migration: first save after wire-up, sweep existing IDB rows into Supabase (one-shot; mark `state.migrated_from_idb = true` to avoid re-sweeps).

When wiring, follow the surgical-edit convention (don't restructure existing save/load functions — extend them with cloud-aware branches gated on `sb && sb.auth.user()`).

---

## Key code locations (line numbers approximate as of v111 — drift; use Grep when needed)

| Function/Section | Line |
|---|---|
| `addImageLayer` | ~2400 |
| `addSvgLayer`, `createSvgLayerFromText` | ~2400 |
| `normalizeSvgDimensions`, `inlineSvgStyleClasses` | 2281, 2323 |
| `extractSvgSwatches`, `replaceSvgSwatchColor`, `escapeRegex` | ~2400 |
| `boards`, board state accessors | 886 |
| `makeBoard`, `getBoard`, `renderBoardTabs` | 902, 920, 968 |
| `switchBoard`, `createNewBoard`, `duplicateBoard`, `closeBoard` | 1019, 1035, 1046, 1124 |
| `copySelected`, `pasteClipboard`, `duplicateSelected` | 1147, 1170, 1235 |
| `serializeLayers`, `serializeForUndo`, `deserializeLayers` | 1265, 1295, 1316 |
| `snapshotState`, `undo`, `redo` | 1413, 1424, 1439 |
| `gatherDesignState`, `restoreDesignState` | 1473, 1488 |
| `promptSaveDesign`, `confirmSaveDesign` | 1531, 1564 |
| `idbSaveDesign`, `idbListDesigns`, `idbDeleteDesign`, `idbGetDesign` | ~1500-1550 |
| `bindKeyboardShortcuts` (Tab, arrows, undo/redo, copy/paste) | 1744 |
| `setCanvasSize`, `toggleOverscan`, `zoom`, `fitZoom`, `applyZoom` | ~1870 |
| `selectLayer`, `ensureChromeVisible` | 3231 |
| `renderLayerList` | ~3363 |
| `renderProps`, `buildTextProps`, `buildSvgProps`, etc. | ~2900+ |
| `enterCropMode`, `confirmCrop`, `clearCrop`, `exitCropMode` | ~4900 |
| `cropDisplayToCanvas`, `drawCropOverlay`, `updateCropHandle` | ~4950 |
| Canvas mousedown (selection, drag, resize, rotate hit-test) | ~4796 |
| `mousemove` (drag/resize/rotate) | ~4871 |
| Resize math (rotation correction, group resize) | ~4920 |
| `redraw`, `redrawSoon` | ~5300, ~5360 |
| `drawImageLayer`, `drawSvgLayer`, `drawTextLayer`, etc. | ~5470+ |
| `paintImageShadow` | ~2700 |
| Export modal, `exportImage`, `exportGif` | ~6500-7300 |

---

## Notable behaviors

### Drag perf
Originally clicking a layer rebuilt the entire property panel synchronously before `dragState` was set — text/sticker layers took 50-200ms of work before the next mousemove. Fixed in v91 by deferring `renderLayerList()` + `renderProps()` to the next animation frame via rAF, and setting `selectedId/selectedIds` immediately so other UI reads it correctly.

Canvas mousedown deliberately **bypasses `selectLayer()`** for this reason — it inlines the necessary state updates and defers the heavy rebuild. Consequence: anything you want `selectLayer` to do (like `ensureChromeVisible()`, `redraw()`) also needs to be called in the inline canvas-mousedown path.

`redrawSoon()` coalesces redraws to one per animation frame so high-DPI mice generating 200+ Hz mousemoves don't overflow the render queue.

### Crop system (v93 rewrite)
`cropState` stores the crop rectangle as **display fractions** (`cropFx/Fy/Fw/Fh` ∈ [0..1]) of the layer's currently-displayed area, not source-image pixels. On confirm:
1. Display fraction is composed with the layer's existing crop (source-pixel space) to produce the new source crop
2. Layer's `x/y/w/h` resize to match on-canvas crop box position and size
3. `_baseW/_baseH` update to new size (so "Reset Scale" reflects current crop)

Re-cropping just produces a tighter crop. "Reset Crop" grows the layer back to full image anchored on cropped center.

### SVG processing
Adobe Illustrator exports often use CSS-defined fills (`<style>.g{fill:url(#f);}` + `class="g"`). When loaded into `<img>` for canvas rendering, some browsers fail to apply style-defined fills, rendering elements black or blank. Fix: `inlineSvgStyleClasses` parses `<style>` blocks and pushes fill/stroke declarations as direct attributes on each element. Runs as part of `normalizeSvgDimensions`.

Both the "+ SVG" button and the file-drop handler call `createSvgLayerFromText()` for identical normalization (v107 unified — drop handler used to bypass `normalizeSvgDimensions` entirely).

### SVG recolor (v109)
`extractSvgSwatches(svgText)` scans for:
- Direct `fill`/`stroke` attributes on elements (deduplicated)
- `<stop>` elements inside `<linearGradient>`/`<radialGradient>` (one swatch per stop, grouped by gradient id)

Returns a flat list of `{kind, key, rawValue, currentHex, label, groupLabel}`. Each becomes an `<input type="color">` in the SVG property panel. On change, `replaceSvgSwatchColor` updates SVG text, revokes old blob URL, creates new one, reloads the `<img>`. `snapshotState` fires for undo. Changes persist via `svgText`.

### Memory management (v111)
The crash fix removed image base64 from undo snapshots. Snapshots store layer transforms (position, size, rotation, opacity) but not source data. On restore, deserializer copies live image/video refs from current `layers` by id. **If adding a new layer type with large embedded data, follow this pattern**: keep src/data fields out of `serializeForUndo`, restore from live layers in `deserializeLayers`.

`deleteLayer` now revokes the layer's blob URL if present, preventing slow leaks from SVG/framed-image blobs.

### Catnip Photo font
CBDT/CBLC OpenType bitmap font built from a photograph of catnip pieces arranged into letters. 40 glyphs.

Build pipeline lived in `/home/claude/` in the prior (Claude.ai web) environment — **not currently in this repo**. If a rebuild is ever needed, re-import:
- `build_glyphs_v3.py` — extracts glyphs from source photo via connected-component analysis
- `build_font_v3.py` — assembles CBDT/CBLC via fontTools
- `glyphs_v3/*.png` + `metrics.json` — 40 glyph images
- `CatnipPhoto_v3.otf` — compiled font (currently embedded as base64 in `CATNIP_PHOTO_FONT_DATA`)

Key metrics: `em=1024`, `cap_height_target=120` at strike, `x_height_target=86`, `descent=0.5×cap_height=60px` (bumped from 30% in v98 — 'g' descender was clipping), strike ppem=120, descent in em units=358.

Classification (typographically forced regardless of source photo):
- x-height: `acemnorsuvwxz`
- Cap-height ascenders: `bdfhkl`
- Short ascender: `t`
- Cap-height with descender: `j`
- Descenders: `gpqy`
- Digits + `!?$`: cap height
- Period: small

---

## Recent work (v85 → v111, most recent first)

| Version | Summary |
|---|---|
| **v111** | Memory fix: lightweight undo snapshots (no base64 src), blob URL revoke on delete. Save dialog ↔ board name sync. |
| **v110** | Multi-select via Ctrl/Shift+click on canvas. Group resize (all selected scale proportionally around top-left). `switchBoard` uses `setCanvasSize` so overscan state honored. |
| **v109** | SVG color swatch remap — color picker per direct fill + per gradient stop. |
| **v108** | SVG flip H/V buttons. |
| **v107** | Refactored SVG layer creation into shared `createSvgLayerFromText` (drop handler was bypassing normalization). |
| **v106** | Canvas-click selection chrome redraws immediately (was deferred after drag perf fix). |
| **v105** | `inlineSvgStyleClasses` — push CSS class fills as direct attributes so `<img>`-loaded SVGs render correctly. |
| **v104** | Two-pass selection outline (white halo + green dashed). Bigger handles. `selectLayer` now redraws. |
| **v103** | Rotation-aware resize math — drag delta rotated by `-rotation` into layer's local space. Fixes upside-down layers growing on inward drag. |
| **v102** | Tab cycles layers (Shift+Tab back). Arrow keys nudge 1px (Shift = 10px). Coalesce undo for arrow-nudge holds. Auto-overscan when chrome falls outside canvas. |
| **v101** | Board duplication. ⎘ icon on each board tab. |
| **v100** | Off-canvas click debug logging. |
| **v99** | Export improvements: 1.5× scale option, default quality 80, file-size hint. |
| **v98** | Catnip Photo font descent bumped 0.3 → 0.5× cap-height to fix 'g' clipping. |
| **v97** | Overscan toggle. |
| **v96** | Crop debug logging. |
| **v95** | Save/update designs. `_currentDesignId` tracks open IDB record. |
| **v94** | Drag perf diagnostic (Ctrl+Shift+P). |
| **v93** | Crop system rewrite — display fractions, proper resize on confirm, anchor-on-center clear. |
| **v92** | rAF-throttled `redrawSoon` for drag/resize/rotate/marquee/crop. |
| **v91** | Deferred panel rebuild via rAF after canvas mousedown. |
| **v89–v90** | Emoji picker with full Unicode + curated favorites. |
| **v85–v88** | Catnip Photo CBDT/CBLC font built and integrated. |

---

## Known issues / pitfalls

### Drag delay reported in user's browser but not in preview
Not fully resolved. v92 (rAF throttling) + v94 (perf diagnostic) are partial mitigations. User hasn't confirmed status. Diagnostic remains in v111 — Ctrl+Shift+P, drag a layer, check console for `[perf]` lines.

### 'g' descender clipping (resolved? unconfirmed)
v98 bumped declared descent. User didn't confirm before moving on.

### Off-canvas click selection (resolved? unconfirmed)
User reported clicks in off-canvas area didn't select layers when overscan was on. v100 added `[overscan-click]` debug logging. User didn't paste output. Math looks correct on inspection.

### Crop on second image (resolved in v93, user later said "still messed up")
v93 rewrote crop. v96 added debug logging. User didn't paste `[crop]` output. Worth re-checking with current crop system.

### `getLayerAt` uses AABB hit-testing
Rotated layers are hit-tested against their unrotated bounding box, not the rotated polygon. Fine for most angles; extreme rotations can feel slightly off. Acceptable unless complained about.

### Large image undo edge case
Undoing a delete of a layer whose image isn't in live `layers` cache (e.g., the layer was the only owner) restores the layer with no image. Serialized snapshot omits src to save memory. Acceptable per v111 tradeoff; if user reports it, a per-id image cache outside `layers` could be added.

### Inline `<style>` regex in SVG
`inlineSvgStyleClasses` only matches single-class selectors `.foo { ... }`. Multi-class, descendant, pseudo-classes ignored. Fine for Illustrator/Inkscape; won't handle hand-written SVGs with complex CSS.

### Canvas-tainting on cross-origin images
Some cross-origin images without CORS headers taint canvas, breaking `toDataURL`/`toBlob` on export. Shopify brand assets are CORS-configured; user uploads are base64'd into data URLs so same-origin. Future features loading arbitrary URLs need to handle CORS.

### YouTube video embedding (parked)
User asked about pasting YouTube links into video picker. Direct rendering not feasible (no direct video URLs from YouTube + canvas-taint). Discussed: thumbnail-as-image-layer (recommended), iframe overlay with thumbnail export, manual download. User said "switch gears." Pick up if asked.

### Background removal on images (parked)
User asked, then chose to "think about it." Constraints: AGPL on `@imgly/background-removal`, ESM-only loading, alternatives (`@xenova/transformers` MIT-licensed, Remove.bg cloud API, click-to-pick chroma-key). No code shipped. Sprinkle-layer `bgRemove`/`bgTolerance`/`keyOutBackground` infra exists as a starting template.

---

## What the user values
- **Honesty about uncertainty.** When working blind on a bug, say so and add diagnostics rather than guessing.
- **Specificity in explanations.** Why the bug existed, not just "I fixed it."
- **Caveats called out.** Edge cases not handled, things not run-tested.
- **Minimal scope creep.** Don't bundle "while I'm in there" changes; ship the requested change and move on.
- **Surgical edits.** Read code before changing it.

Jason is a busy operator running marketing for SmarterPaw. He uses this tool daily. Performance issues, crashes, and "I lost my work" moments are highest-priority. Visual polish and new features are secondary.

---

## Common request patterns

1. **"X doesn't work" / "X is weird"** — diagnose first. Read the relevant code, trace the flow, hypothesize. If you can't reproduce from code alone, add console logging and ship a diagnostic version. Ask for console output.
2. **"Add a way to do Y"** — propose implementation approach first if there are real tradeoffs. Otherwise just ship.
3. **"What about Z?" (open-ended)** — explain constraints, propose 2-3 options.
4. **Bug reports phrased as features ("It should X")** — usually means existing behavior surprised them. Find existing code, understand why it works that way, then fix or explain.

---

## Quick orientation queries

```bash
# Top-level functions
grep -n "^function " index.html

# Globals
grep -n "^var " index.html

# Draw functions per layer type
grep -n "^function draw" index.html

# Property panel builders
grep -n "function build.*Props" index.html

# Event listeners
grep -n "addEventListener" index.html
```

---

## Versioning
Bump the version string at one line near the top of `<body>`: `<span>SmarterPaw Marketing · v111</span>` → `v112` on every shippable change. The current version string in `gatherDesignState()`'s `appVersion: 'v42'` is stale — out of sync with the body version. Leave it for now; reconcile when the Supabase wire-up lands (good time to add `appVersion: getCurrentVersionString()` reading from the body).
