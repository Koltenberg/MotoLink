# Moto Link 0.4.10 app icon

The iOS icon is an original generated pixel-art red/graphite motorcycle on an opaque dark background. The large bike silhouette and two wheels remain recognizable in 60px and 120px previews. There is no letter mark, trademark, wordmark, baked rounded mask or transparent channel. iOS supplies its own icon mask.

## Asset

- Project path: `ios/MotoLink/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- Format: 1024 × 1024 PNG, RGB, opaque; 803,013 bytes.
- SHA-256: `66fda67805372c21fac36ac56125fae10dec70cdfbb54a7b03762e9bad36b2e5`
- Created 2026-09-27 with the built-in image generation tool; no CLI/API fallback, no reference images, no user photographs or identifiers.
- Generated source: 1254 × 1254 RGB PNG. Deterministic processing: Pillow `convert("RGB").resize((1024,1024), Image.Resampling.NEAREST)`, then PNG save with `optimize=True`. Nearest-neighbor keeps hard pixel edges; there was no compositing or generative retouching.
- Visual QA: inspected full generated image and Lanczos downscaled 60px/120px previews. Red tank, headlamp and both wheels stay distinguishable. The asset catalog's existing universal iOS 1024 entry is unchanged.

## Generation prompt

The prompt records the creative provenance; image generation is nondeterministic, so regenerating this prompt is not a byte-for-byte reproduction. The hash above identifies the shipped artwork.

```text
Use case: stylized-concept
Asset type: final iOS app icon for Moto Link, a personal motorcycle garage, ride and maintenance companion. Generate one 1024x1024 image.
Primary request: a truly pixel-art, handsome black/graphite and scarlet-red modern 500cc street motorcycle as a clear app symbol, carrying the feeling of a beloved personal bike in a tiny game garage. Authentic intentional pixel clusters, not a smooth illustration with a pixel filter.
Subject: one red-and-graphite sporty naked motorcycle, dynamic but parked, bold recognizable side silhouette slightly turned toward the viewer, facing right. Two solid readable wheels, sculpted red fuel tank, black saddle, compact angular headlight with a restrained warm-white highlight, silver small engine details. No rider. Motorcycle occupies about 78% width and 57% height centered, large simple masses strong enough to recognize at 60px. Art direction: finely composed premium indie-game pixel art, effective coarse 64x64 to 96x96 pixel grid scaled crisply, restrained stepped highlights and charming mechanical detail without noise.
Scene/backdrop: flat near-black graphite square background reaching all four edges, subtly lighter squared pixel backing halo behind the bike, minimal short ground shadow. No frame, no rounded corners, no vignette blur. Polished luminous red highlights visibly separate the silhouette from background.
Palette: graphite #15191D, charcoal #262B32, vivid scarlet #F04D46, dark red #982D34, warm off-white #F2E9DD, restrained silver-gray. High luminance contrast.
Constraints: 1024 square opaque full-bleed app-icon PNG. Crisp square hard-edged pixels and stepped diagonals only, even visual pixel scale. No text, no letters, no ML monogram, no numerals, no logos or Kawasaki wordmark, no border, no rounded app mask, no extra icons, no checkmarks, no scenery, no gradients, no photorealism, no 3D-render softness, no blur, no watermark.
```
