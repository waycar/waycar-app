#!/usr/bin/env python3
"""Generate every Waycar logo asset from one set of shapes.

Two marks, each in several palettes:

- Caboose: a flat caboose (cupola, body, two wheels, track) with a `>_`
  shell prompt cut out of its side.
- Prompt: the `>_` glyph alone, the underscore riding on two wheels.

Outputs (all committed; rerun after changing anything here):

- `Sources/Waycar/AppIcons/<name>.icon`: Icon Composer bundles. `AppIcon` is
  the primary icon; the rest are alternate icons the user picks in Settings
  (`AppIconOption`, `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`). Each is a
  solid fill plus one transparent foreground layer, so iOS can derive its
  dark and tinted renditions.
- `Sources/Waycar/AppIconPreviews.xcassets`: an Icon Composer render of each
  icon for the Settings picker (iOS cannot hand back an alternate icon's image).
- `docs/images/waycar-icon.svg`, `docs/images/logo.png`: the primary icon.
- `apps/web/src/assets/logo.png` and `apps/web/public/{favicon.ico,
  favicon.svg,favicon-{32,48,96}.png,apple-touch-icon.png,icon-{192,512}.png}`:
  the marketing site. Search engines want `/favicon.ico` and an icon of at
  least 48 px, so the small sizes all use the prompt mark.

The site's share cards (`apps/web/public/og*.png`) are not made here: they are
HTML under `apps/web/og/`, rendered by its `render.sh`, and show
`docs/images/waycar-icon.svg`, so rerun that after changing the primary icon.

Needs `rsvg-convert` (Homebrew librsvg) and Xcode's Icon Composer `ictool`.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "Sources/Waycar/AppIcons"
PREVIEWS = ROOT / "Sources/Waycar/AppIconPreviews.xcassets"

def find_ictool() -> Path:
    """Icon Composer's CLI inside the active Xcode (`xcode-select -p`)."""
    developer = subprocess.run(
        ["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip()
    return Path(developer).parent / "Applications/Icon Composer.app/Contents/Executables/ictool"


ICTOOL = find_ictool()
PREVIEW_PX = 180


@dataclass(frozen=True)
class Palette:
    ground: str  # icon fill; the prompt and wheel hubs are cut through to it
    body: str  # the mark itself
    window: str  # cupola window
    rail: str  # track under the caboose


PALETTES = {
    # Brand ground (`bg`) and violet (`violet`) from design/tokens.json.
    "violet": Palette("#07080B", "#8B5CF6", "#EDE9FE", "#1E1A2E"),
    "phosphor": Palette("#0F1512", "#3BD67F", "#E8FFF1", "#22302A"),
    "tomato": Palette("#F4EEE3", "#E4572E", "#2A2A2A", "#E2D8C6"),
    "signal": Palette("#FFD23F", "#151515", "#FFD23F", "#EBBE2B"),
    "cobalt": Palette("#2B59C3", "#FFFFFF", "#FFD166", "#3D6BD4"),
    "mono": Palette("#FAFAFA", "#141414", "#FAFAFA", "#E6E6E6"),
    "black": Palette("#000000", "#FFFFFF", "#000000", "#2A2A2A"),
    "teal": Palette("#123C3D", "#F2A541", "#FCE7C4", "#1C4D4E"),
    "amber": Palette("#17120D", "#FFB000", "#FFE3A3", "#2E2419"),
    "coral": Palette("#23262B", "#FF6B5B", "#F5E9DA", "#33373E"),
}

# (asset name, mark, palette). Order is the Settings picker's order within a
# mark; `AppIconOption` in Swift must list the same names.
ICON_SET = [
    ("AppIcon", "caboose", "violet"),
    ("AppIconCaboosePhosphor", "caboose", "phosphor"),
    ("AppIconCabooseTomato", "caboose", "tomato"),
    ("AppIconCabooseSignal", "caboose", "signal"),
    ("AppIconCabooseCobalt", "caboose", "cobalt"),
    ("AppIconCabooseMono", "caboose", "mono"),
    ("AppIconCabooseBlack", "caboose", "black"),
    ("AppIconCabooseTeal", "caboose", "teal"),
    ("AppIconPromptPhosphor", "prompt", "phosphor"),
    ("AppIconPromptAmber", "prompt", "amber"),
    ("AppIconPromptMono", "prompt", "mono"),
    ("AppIconPromptBlack", "prompt", "black"),
    ("AppIconPromptCoral", "prompt", "coral"),
]


def prompt_glyph(cx: float, cy: float, scale: float, width: float, color: str) -> str:
    """`>_` centred on (cx, cy)."""
    return (
        f'<g transform="translate({cx} {cy}) scale({scale})" fill="none" stroke="{color}" '
        f'stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round">'
        '<path d="M-100 -62 L-30 0 L-100 62"/><path d="M20 62 L110 62"/></g>')


def caboose(p: Palette) -> str:
    """Foreground only; transparent where the fill should show."""
    hubs = '<circle cx="360" cy="716" r="20"/><circle cx="664" cy="716" r="20"/>'
    return f'''<defs><mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
<rect width="1024" height="1024" fill="white"/><g fill="black">{hubs}</g>
{prompt_glyph(512, 540, 1.15, 38, "black")}</mask></defs>
<rect x="120" y="778" width="784" height="20" rx="10" fill="{p.rail}"/>
<g fill="{p.body}" mask="url(#cut)">
<rect x="392" y="236" width="240" height="150" rx="28"/>
<rect x="196" y="352" width="632" height="36" rx="18"/>
<rect x="232" y="370" width="560" height="330" rx="44"/>
<circle cx="360" cy="716" r="58"/><circle cx="664" cy="716" r="58"/></g>
<rect x="452" y="278" width="120" height="60" rx="16" fill="{p.window}"/>'''


def prompt(p: Palette) -> str:
    return f'''<defs><mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
<rect width="1024" height="1024" fill="white"/>
<circle cx="600" cy="740" r="16" fill="black"/><circle cx="730" cy="740" r="16" fill="black"/></mask></defs>
<g fill="none" stroke="{p.body}" stroke-width="84" stroke-linecap="round" stroke-linejoin="round">
<path d="M250 250 L450 430 L250 610"/><path d="M540 610 L790 610"/></g>
<g fill="{p.body}" mask="url(#cut)"><circle cx="600" cy="740" r="48"/><circle cx="730" cy="740" r="48"/></g>'''


MARKS = {"caboose": caboose, "prompt": prompt}


def svg(inner: str, ground: str | None = None) -> str:
    bg = f'<rect x="-10000" y="-10000" width="20000" height="20000" fill="{ground}"/>' if ground else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f"{bg}{inner}</svg>\n")


def render(svg_text: str, out: Path, tmp: Path, px: int) -> None:
    src = tmp / "in.svg"
    src.write_text(svg_text)
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["rsvg-convert", "-w", str(px), "-h", str(px), str(src), "-o", str(out)], check=True)


def write_ico(pngs: list[Path], out: Path) -> None:
    """A .ico holding PNG images as-is (valid since Windows Vista; every
    browser and search engine reads it)."""
    import struct
    blobs = [p.read_bytes() for p in pngs]
    offset = 6 + 16 * len(blobs)
    header = struct.pack("<HHH", 0, 1, len(blobs))
    entries = b""
    for blob in blobs:
        w, h = struct.unpack(">II", blob[16:24])
        entries += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    out.write_bytes(header + entries + b"".join(blobs))


def srgb(hex_color: str) -> str:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def write_icon(name: str, mark: str, p: Palette, tmp: Path) -> Path:
    bundle = ICONS / f"{name}.icon"
    if bundle.exists():
        shutil.rmtree(bundle)
    render(svg(MARKS[mark](p)), bundle / "Assets/foreground.png", tmp, 1024)
    manifest = {
        "fill": {"solid": srgb(p.ground)},
        "groups": [{
            "layers": [{"image-name": "foreground.png", "name": "foreground", "glass": False}],
            "shadow": {"kind": "neutral", "opacity": 0.25},
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": "shared"},
    }
    (bundle / "icon.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return bundle


def write_preview(name: str, bundle: Path) -> None:
    imageset = PREVIEWS / f"{name}Preview.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [str(ICTOOL), str(bundle), "--export-image", "--output-file", str(imageset / "preview.png"),
         "--platform", "iOS", "--rendition", "Default",
         "--width", str(PREVIEW_PX), "--height", str(PREVIEW_PX), "--scale", "1"],
        check=True, stdout=subprocess.DEVNULL)
    (imageset / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "preview.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")


def main() -> int:
    for tool in ("rsvg-convert",):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found (brew install librsvg)")
    if not ICTOOL.exists():
        sys.exit(f"ictool not found at {ICTOOL}")

    if PREVIEWS.exists():
        shutil.rmtree(PREVIEWS)
    PREVIEWS.mkdir(parents=True)
    (PREVIEWS / "Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        for name, mark, palette in ICON_SET:
            write_preview(name, write_icon(name, mark, PALETTES[palette], tmp))

        # The primary icon, full-bleed, for docs and the site.
        primary = PALETTES[next(p for n, _, p in ICON_SET if n == "AppIcon")]
        full = svg(caboose(primary), primary.ground)
        (ROOT / "docs/images/waycar-icon.svg").write_text(full)
        for out, px in [
            ("docs/images/logo.png", 1024),
            ("apps/web/src/assets/logo.png", 1024),
            ("apps/web/public/icon-512.png", 512),
            ("apps/web/public/apple-touch-icon.png", 180),
        ]:
            render(full, ROOT / out, tmp, px)
        render(full, ROOT / "apps/web/public/icon-192.png", tmp, 192)
        # At favicon sizes the caboose's track and hubs turn to mush; the
        # favicons are the bare prompt mark, which survives.
        mark = svg(prompt(primary), primary.ground)
        public = ROOT / "apps/web/public"
        (public / "favicon.svg").write_text(mark)
        for px in (32, 48, 96):
            render(mark, public / f"favicon-{px}.png", tmp, px)
        for px in (16,):
            render(mark, tmp / f"favicon-{px}.png", tmp, px)
        write_ico([tmp / "favicon-16.png", public / "favicon-32.png", public / "favicon-48.png"],
                  public / "favicon.ico")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
