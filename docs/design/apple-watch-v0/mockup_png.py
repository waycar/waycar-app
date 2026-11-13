"""PNG export for the Waycar Apple Watch V0 mockups via rsvg-convert (librsvg).

On macOS the SF fonts are installed only under hidden family names (".SF Compact", ".SF NS Mono").
librsvg's default CoreText path can't select those names, so rendering forces Pango's fontconfig
backend with a private config that includes the normal fontconfig setup and rejects the italic SF
files (otherwise fontconfig can pick the italic face for a roman request). Stdlib only.
"""
import os
import shutil
import subprocess
import sys
import tempfile

_CONF = '''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <include ignore_missing="yes">/opt/homebrew/etc/fonts/fonts.conf</include>
  <include ignore_missing="yes">/usr/local/etc/fonts/fonts.conf</include>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
  <selectfont><rejectfont>
    <glob>*/SFCompactItalic.ttf</glob>
    <glob>*/SFNSMonoItalic.ttf</glob>
  </rejectfont></selectfont>
</fontconfig>
'''


class Renderer:
    """Context manager: renders SVG strings to PNG files with the real SF faces."""

    def __enter__(self):
        self.exe = shutil.which('rsvg-convert')
        if not self.exe:
            sys.exit('make_mockups: rsvg-convert not found; install librsvg (brew install librsvg) to export png/.')
        self.tmp = tempfile.mkdtemp(prefix='waycar-watch-png-')
        conf = os.path.join(self.tmp, 'fonts.conf')
        with open(conf, 'w', encoding='utf-8') as fh:
            fh.write(_CONF)
        self.env = dict(os.environ, FONTCONFIG_FILE=conf, PANGOCAIRO_BACKEND='fc')
        return self

    def render(self, svg, out_png):
        """Render at the SVG's own width/height attributes."""
        subprocess.run([self.exe, '-f', 'png', '-o', out_png], input=svg.encode('utf-8'), env=self.env, check=True)

    def __exit__(self, *exc):
        shutil.rmtree(self.tmp, ignore_errors=True)
