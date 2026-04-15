# Asset Handling for iOS/SwiftUI

How to process Figma assets for use in Xcode projects.

## Always Download from Figma

Every icon and image in the design MUST be downloaded from the Figma MCP server. Do NOT substitute with SF Symbols or any other icon system — always use the exact asset from Figma to guarantee pixel-perfect fidelity with the design.

The only exception: if the user explicitly asks to use SF Symbols for specific icons.

## Extracting Assets from MCP Response

`get_design_context` returns localhost download URLs for image assets in the design. These URLs are ephemeral — they only live while the MCP session is active. Download them immediately.

### What to look for in the response:
- Image fills on frames (photos, illustrations, backgrounds)
- Icons with raster content (not simple vector shapes)
- Assets marked for export in Figma

### What to download vs what to code:
- **Download as PNG:** All images and icons — photos, illustrations, logos, icons, brand assets
- **Code:** Simple geometric shapes (rectangles, circles), solid fills, gradients
- **IMPORTANT:** Always download as PNG format. Do NOT download SVGs. If the MCP returns SVG data, convert it to PNG or re-export the node as PNG using `get_screenshot`.

### Downloading assets:

**CRITICAL — Validate file format after download.** Figma MCP localhost URLs do not guarantee the file extension matches the actual content. A URL may serve SVG data even if you save it as `.png`. Always validate:

```bash
# Download the asset
curl -o filename_raw "http://localhost:PORT/path/to/asset"

# Check actual file type
file filename_raw
# If output contains "SVG" or "XML" -> rename to .svg
# If output contains "PNG image data" -> rename to .png
# If output contains "JPEG image data" -> rename to .jpg
```

**Automated validation script:**
```bash
DOWNLOADED="filename_raw"
ACTUAL_TYPE=$(file -b "$DOWNLOADED")
TARGET="${DOWNLOADED%_raw}.png"

if echo "$ACTUAL_TYPE" | grep -qi "svg\|xml"; then
  # SVG detected — do NOT use as-is. Re-export as PNG using get_screenshot instead.
  echo "WARNING: File is SVG, not PNG. Use get_screenshot(fileKey, nodeId) to export as PNG."
  rm "$DOWNLOADED"
elif echo "$ACTUAL_TYPE" | grep -qi "png"; then
  mv "$DOWNLOADED" "$TARGET"
elif echo "$ACTUAL_TYPE" | grep -qi "jpeg\|jpg"; then
  # Convert JPEG to PNG for consistency
  sips -s format png "$DOWNLOADED" --out "$TARGET" && rm "$DOWNLOADED"
else
  echo "WARNING: Unknown file type: $ACTUAL_TYPE — re-export with get_screenshot"
  rm "$DOWNLOADED"
fi
```

**Why this matters:** Xcode silently fails to render images when the file extension does not match the actual content (e.g., an SVG file saved as `.png`). Always validate with `file` command. If the content is SVG, discard it and use `get_screenshot(fileKey, nodeId)` to export the node as PNG instead.

Download each asset as soon as you extract the URL. If a URL returns an error or times out, the session may have expired — re-run `get_design_context` for fresh URLs.

### Using `download_figma_images` MCP tool (preferred):

If the `download_figma_images` MCP tool is available, prefer it over manual curl. It handles format detection and downloading automatically:
- Pass the node IDs and desired filenames
- It saves PNG and SVG files with correct extensions
- Set `localPath` to your asset cache directory

### Fallback — get_screenshot for individual nodes:
If an asset has no download URL in the `get_design_context` response (e.g., a custom icon or illustration), use `get_screenshot(fileKey, nodeId)` targeting that specific node to export it as PNG.

## Raster Images (PNG, JPG)

### From Figma MCP localhost URL:
1. Download the image from the localhost URL provided by MCP
2. Generate @1x, @2x, @3x variants (if MCP provides only one size, use the highest resolution as @3x and scale down)
3. Add to the project's Asset Catalog (Assets.xcassets)
4. Create an imageset with all three scale variants
5. Use in SwiftUI: Image("assetName")

### Naming convention:
- Use kebab-case or camelCase matching project convention
- Prefix every Figma-derived asset with the screen name or source node name, then the asset purpose
- Prefer screen/node prefixes that already match nearby code and asset naming
- Examples: `onboardingHero`, `profileHeaderPlaceholder`, `checkout-summary-illustration`
- Do not use spaces or special characters
- Before creating a new asset entry, search the existing Asset Catalog and project resources for a matching asset and reuse it if possible

### Asset Catalog structure:
```
Assets.xcassets/
  Images/
    onboarding-hero.imageset/
      onboarding-hero@1x.png
      onboarding-hero@2x.png
      onboarding-hero@3x.png
      Contents.json
```

### Contents.json for raster imageset:
```json
{
  "images": [
    { "filename": "asset-name@1x.png", "idiom": "universal", "scale": "1x" },
    { "filename": "asset-name@2x.png", "idiom": "universal", "scale": "2x" },
    { "filename": "asset-name@3x.png", "idiom": "universal", "scale": "3x" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

### Generating scale variants with sips:
Use the downloaded image as @3x source (highest resolution). Scale down for @2x and @1x:
```bash
# Example: source is 300x300 for a 100pt asset
cp source.png asset-name@3x.png
sips -Z 200 source.png --out asset-name@2x.png
sips -Z 100 source.png --out asset-name@1x.png
```
The `-Z` flag scales to fit within NxN pixels while preserving aspect ratio.

## Vector Assets — PNG Only

Do NOT use SVG files. All icons and vector assets must be exported as PNG.

If the MCP returns SVG content instead of PNG:
1. Discard the SVG file
2. Use `get_screenshot(fileKey, nodeId)` targeting the specific icon node to export as PNG
3. Use the PNG export with @1x/@2x/@3x variants in Asset Catalog (same as raster images above)

For tintable icons, use `.renderingMode(.template)`:
```swift
Image("iconName")
    .renderingMode(.template)
    .foregroundColor(.primary)
```

## Remote Images

If the design references images loaded from a URL (user avatars, feed content):

1. Check project dependencies (Package.swift, Podfile, .xcodeproj) for an existing image loading library (Kingfisher, SDWebImage, Nuke, etc.)
2. If found — use the project's library and follow its existing patterns in the codebase
3. If not found — ask the user which approach to use before implementing. Do not default to AsyncImage without confirmation.

Do NOT download remote images as local assets.

## Asset Rules Summary

1. Always download icons and images from Figma MCP — never substitute with SF Symbols unless the user explicitly asks
2. Always validate file format after download — use `file` command to detect real type and rename extension accordingly
3. Reuse existing project assets before adding new ones
4. Download from MCP — use `download_figma_images` tool when available, otherwise curl + validate
5. PNG only — never use SVG. If MCP returns SVG, re-export with `get_screenshot` as PNG
6. All images and icons: @1x/@2x/@3x PNG variants in Asset Catalog
7. Remote images: use project's image loading library, ask user if none found
8. Do NOT add new icon library dependencies
9. Prefix Figma-derived asset names with the screen or source node name
10. Match project naming conventions for all assets
