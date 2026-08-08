#!/usr/bin/env python3
"""WCAG AA contrast gate for every fleet theme.

Parses the palette tokens out of fleet.css and checks each pair that actually
carries text against WCAG 2.1 AA. Run it after touching any theme:

    python3 docs/the-fleet/tools/check-contrast.py

Exit code is non-zero if any pair fails, so it can gate CI.

Which pairs and why 4.5:1 for all of them: every one of these tokens is used
somewhere at normal body or small-label size (.refs and the footer run at
.74rem, well under the 18.66px large-text threshold), so none of them get to
claim the 3:1 large-text allowance.
"""
import re
import sys
import pathlib

CSS = pathlib.Path(__file__).resolve().parent.parent / "fleet.css"

# text token -> the surfaces it is painted on
PAIRS = [
    ("bone",       ["ground", "ground-2", "ground-3"]),   # body + card + strip text
    ("bone-dim",   ["ground", "ground-2", "ground-3"]),   # ledes, glosses, captions
    ("bone-faint", ["ground", "ground-2", "ground-3"]),   # .refs, .spoke, footer
    ("gold",       ["ground", "ground-2", "ground-3"]),   # eyebrows, links, laws
    ("jade",       ["ground", "ground-2"]),               # .role-sub, volatile channel
    ("flare",      ["ground", "ground-2"]),               # .inc .idx, callout eyebrow
]

AA = 4.5


def srgb_to_lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hex_color):
    h = hex_color.lstrip("#")
    if len(h) == 3:
        h = "".join(ch * 2 for ch in h)
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * srgb_to_lin(r) + 0.7152 * srgb_to_lin(g) + 0.0722 * srgb_to_lin(b)


def ratio(fg, bg):
    a, b = luminance(fg), luminance(bg)
    lo, hi = min(a, b), max(a, b)
    return (hi + 0.05) / (lo + 0.05)


def parse_themes(css):
    """Return {theme_name: {token: hex}} for every palette block in the file."""
    themes = {}

    def tokens_in(block):
        found = {}
        for name, value in re.findall(r"--([a-z0-9-]+)\s*:\s*(#[0-9A-Fa-f]{3,8})\s*;", block):
            found[name] = value
        return found

    # the default (dark) palette
    root = re.search(r"^:root\s*\{(.*?)^\}", css, re.S | re.M)
    if root:
        themes["default (dark)"] = tokens_in(root.group(1))

    # the default light override
    light = re.search(r":root:not\(\[data-theme\]\)\s*\{(.*?)\n  \}", css, re.S)
    if light:
        base = dict(themes.get("default (dark)", {}))
        base.update(tokens_in(light.group(1)))
        themes["default (light)"] = base

    # every named theme
    for name, block in re.findall(r':root\[data-theme="([a-z]+)"\]\s*\{(.*?)^\}', css, re.S | re.M):
        toks = tokens_in(block)
        if "ground" in toks:                      # palette block, not a tweak block
            themes[name] = toks
    return themes


def main():
    css = CSS.read_text(encoding="utf-8")
    themes = parse_themes(css)
    if not themes:
        print("no themes parsed — did fleet.css move?")
        return 1

    failures = []
    print(f"WCAG AA (>= {AA}:1) — {len(themes)} themes\n")

    for theme in sorted(themes, key=lambda t: (not t.startswith("default"), t)):
        toks = themes[theme]
        worst_name, worst = None, 99.0
        checked = 0
        for fg, grounds in PAIRS:
            if fg not in toks:
                continue
            for bg in grounds:
                if bg not in toks:
                    continue
                r = ratio(toks[fg], toks[bg])
                checked += 1
                if r < worst:
                    worst, worst_name = r, f"{fg} on {bg}"
                if r < AA:
                    failures.append((theme, fg, toks[fg], bg, toks[bg], r))
        mark = "FAIL" if any(f[0] == theme for f in failures) else "pass"
        print(f"  [{mark}] {theme:<18} {checked:>2} pairs   worst {worst:5.2f}:1  ({worst_name})")

    # the hero is hardcoded rather than tokenised — check it on its own
    print("\n  hero (fixed walnut card, all themes):")
    for fg, label in [("#F7F0DE", "h1"), ("#D9CBAE", "standfirst"), ("#E7BA5C", "eyebrow / h1 em")]:
        r = ratio(fg, "#171109")
        state = "pass" if r >= AA else "FAIL"
        print(f"    [{state}] {label:<18} {fg} on #171109   {r:5.2f}:1")
        if r < AA:
            failures.append(("hero", label, fg, "hero", "#171109", r))

    if failures:
        print(f"\n{len(failures)} FAILING PAIR(S):\n")
        for theme, fg, fgv, bg, bgv, r in failures:
            print(f"  {theme:<18} --{fg} {fgv} on --{bg} {bgv}  =  {r:.2f}:1  (needs {AA})")
        return 1

    print("\nAll token pairs clear WCAG AA.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
