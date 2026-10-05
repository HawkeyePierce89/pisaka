# Vendored: the design's glyphs

This file is a **record, not a resource**. The glyphs themselves ship from the
app's asset catalog, `Sources/Pisaka/Assets.xcassets/Glyphs/`, one template
vector imageset per glyph; this directory is not listed in `project.yml`'s
resources, so nothing here is copied into the app. It exists because the
catalog's `Contents.json` files have no room for provenance, and the
acknowledgement in `Resources/Licenses/licenses.json` needs a record its
`revision` and `version` can be checked against — `LicenseCoverageTests` reads
the section below, and `DesignGlyphAssetTests` reads the glyph table.

## design-glyphs

| | |
|---|---|
| Source | the design export's `icons/` folder, exported 2026-10-05 (outside the repository) |
| Revision | `85aea20cfbbe52b9c6c445bb3964d0a06db9db7543e1f901ea7350b0999e3a26` |
| Version | `null` |
| Origin | `Sources/Pisaka/Assets.xcassets/Glyphs` |
| License | ISC AND MIT — `Resources/Licenses/design-glyphs.txt`, the export's `LICENSE.txt` copied verbatim |

**Why the revision is a digest.** The export carries no upstream commit and no
release version: it is a folder of PDFs, a `LICENSE.txt` and a `MANIFEST.txt`
listing each PDF's sha256 prefix and box size. The one value that names this
exact set of bytes is therefore the full sha256 of `MANIFEST.txt` itself, and
that is what the acknowledgement records as its revision. There is no version to
name, so the record and the manifest entry both say `null`.

## Glyphs taken

Twenty-four of the export's thirty-two PDFs, each copied byte for byte into
`<name>.imageset/<name>.pdf`. The prefix is the first sixteen hex digits of the
PDF's sha256, as `MANIFEST.txt` lists it; the size is the PDF's box, as the
manifest states it, and it is 24 for every glyph (why, below). The last column says
whether the glyph is one the licence text's MIT notice names (the glyphs derived
from the older set the ISC licence's second section lists); the rest are under
the ISC licence alone.

| Glyph | Prefix | Size | MIT notice |
|---|---|---|---|
| `package` | `4e19fc2e5b0fbd39` | 24 | no |
| `git-branch` | `1738e285c5e53723` | 24 | no |
| `chevron-down` | `8b7df9eda0367c90` | 24 | yes |
| `chevron-right` | `02cd1542fb22ad90` | 24 | yes |
| `git-pull-request` | `37a0975caf14903b` | 24 | no |
| `check` | `496d1749c8eaf0e0` | 24 | yes |
| `terminal` | `992c48725d6efb5d` | 24 | yes |
| `file-warning` | `18a5d9157e3c9fa2` | 24 | no |
| `git-compare` | `2dbb6bb38742483c` | 24 | no |
| `list-checks` | `3456e4aed7e36adb` | 24 | no |
| `search` | `fca0d98489622650` | 24 | yes |
| `git-pull-request-arrow` | `d9250c717269a4c4` | 24 | no |
| `folder` | `8751dad31dc2126f` | 24 | no |
| `folder-open` | `b732124cc847a62f` | 24 | no |
| `file-code` | `4f1e3ceacbac6a29` | 24 | no |
| `file-text` | `d759e0792fcfd2ba` | 24 | no |
| `database` | `94e48ce90170f619` | 24 | yes |
| `x` | `9ffad35485eeffa0` | 24 | yes |
| `user-round` | `5eac37ea03006449` | 24 | no |
| `undo-2` | `3086adea25b52419` | 24 | no |
| `refresh-cw` | `b1dba6c8271f47ff` | 24 | no |
| `case-sensitive` | `7e7229ec9d8a3b64` | 24 | no |
| `whole-word` | `c8f3633e9f9b8492` | 24 | no |
| `regex` | `0f392dda96cecce3` | 24 | no |

The eight left behind (`chevron-left`, `circle`, `circle-check`, `circle-dot`,
`circle-x`, `info`, `minus`, `plus`) are not drawn anywhere, so they do not ship.

Every imageset's `Contents.json` sets `"template-rendering-intent": "template"`,
so the glyph is tinted by whatever colour the drawing site hands it, and
`"preserves-vector-representation": true`, so it stays sharp at every interface
scale rather than being rasterised at its 1x size.

## Why every box is 24

Every PDF's media box is 24×24 because that is the icon set's native viewBox:
its paths keep two units of padding on every side and are stroked at width 2,
so the ink stays about a unit clear of each edge, and the export writes them at
exactly those coordinates. A vector is drawn at whatever size
the surface states, so the design's 10-, 12-, 13-, 14- and 16-point instances of
a glyph are all this one asset. The table's size column is therefore the box, not
a drawn size; the drawn size belongs to each drawing site, which always states it.

## What the previous export got wrong

The export of 2026-10-02 exported each bare icon node rather than a frame around
it. Its media box was the drawn extent rounded down to an integer, while the
geometry inside kept its fractional size; the renderer clips to the box, so right
and bottom edges were cut off. `folder`, for one, was a 12×12 box holding
geometry 12.84 wide. Fifteen of the twenty-four shipped glyphs had geometry
outside their box, thirteen of them visibly clipped.

One drawing changed on purpose with this export. The previous `file-warning.pdf`
was the design tool's "icon not found" placeholder, a question mark in a circle:
the icon set had renamed that glyph while the design file kept the old name. The
new file is the real drawing, a document with an exclamation mark. The asset
name, the `DesignGlyph` case and every use are unchanged.

## Updating by hand

1. Export a 24×24 frame wrapping each icon, **never the bare icon node**: the
   bare node reproduces the rounded-down box that clips the drawing (above).
2. Take the new export's `icons/` folder. Check every PDF you mean to ship
   against its line in the new `MANIFEST.txt` (`shasum -a 256 <name>.pdf`, first
   sixteen hex digits).
3. Prove the export before vendoring it: run `DesignGlyphAssetTests`' geometry
   check against the candidate folder, which fails on any media box other than
   24×24 and on any path coordinate outside it. How to point it at a folder
   outside the catalog, as a throwaway local edit, is in that suite's doc
   comment.
4. Copy each PDF over `Sources/Pisaka/Assets.xcassets/Glyphs/<name>.imageset/<name>.pdf`.
   A new glyph gets a new imageset with the same two properties as its
   neighbours, a new `DesignGlyph` case whose raw value is its name, and a row in
   the table above; a dropped glyph loses all three.
5. Update the table's prefix column, and `DesignGlyphAssetTests`' pinned prefix
   table, from the new manifest. The size column is 24 for every glyph.
6. Take `shasum -a 256 MANIFEST.txt` of the new export and write it into the
   `Revision` row above and the `revision` of the `design-glyphs` entry in
   `Resources/Licenses/licenses.json`.
7. Re-copy `LICENSE.txt` verbatim over `Resources/Licenses/design-glyphs.txt`,
   re-check which shipped glyphs its MIT section lists, and update the last
   column above.
8. Run `swift test`: `DesignGlyphAssetTests` and `LicenseCoverageTests` both fail
   until the catalog, this record, the enum and the manifest entry agree.
