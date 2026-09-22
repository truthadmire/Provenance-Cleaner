# App icon

The 0.2.1 icon uses a graphite rounded square and a single ivory eraser. The
design keeps generous negative space and a strong silhouette at small sizes.

The production master is
`App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`. All ten macOS asset
catalog slots were resampled from the same generated source with macOS `sips`.
The master is 1024 × 1024 and every size preserves the transparent alpha channel.

## Generation

Created with the built-in imagegen tool, using the previous app icon as a visual
reference. The second pass removed the initial image's baked checkerboard and
produced a PNG with actual transparency. No fallback API or CLI was used.

Initial prompt:

> Redesign this macOS app icon for Provenance Cleaner in a rigorously minimalist style. Replace the entire ornate design with one single, bold, instantly recognizable eraser symbol. Final deliverable: one 1024x1024 PNG app-icon asset, not a mockup, no captions or text, no layout sheet. True transparent alpha canvas around a large centered macOS continuous-corner rounded-square tile; tile occupies roughly 88% of canvas with balanced transparent margins, typical macOS app icon shape. Tile is matte deep graphite (#25272B), very subtle edge definition only. Center a simple geometric warm ivory (#F5F2EB) eraser pictogram angled from lower-left to upper-right, with a flat contact edge at its lower end, generous weight and crisp smooth curves. One narrow graphite dividing seam distinguishes the eraser tip from the body; the mark should read as one cohesive eraser, not a USB stick. Symbol occupies about 55% of tile width and height, optically centered, generous negative space. Restrained, elegant, almost flat vector-like execution with exact clean edges and extremely slight native macOS depth. Only graphite and ivory. No shield, no page/document, no fingerprint, no particles, no sparkles, no glow, no chrome, no glossy 3D, no text, no gradients within the symbol, no checkerboard baked into the image. Preserve true transparency outside the tile. This is intended to remain legible at 16, 32 and 64 pixel sizes.

Final edit prompt:

> Background extraction only. Keep this exact graphite rounded square and ivory eraser icon unchanged. Remove ALL white and gray checkerboard outside the rounded square. The checkerboard in the source is accidentally baked into the RGB pixels. Output a PNG with an actual transparent alpha channel outside the tile, clean antialiased edge, fully transparent corners and margins, no visible checkerboard and no background color. Do not draw a transparency pattern. Deliver the actual production macOS app icon asset on real transparency, square aspect ratio. Preserve the icon's shape, colors, proportions, and minimalist style.
