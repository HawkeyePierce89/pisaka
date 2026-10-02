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
| Source | the design export's `icons/` folder, exported 2026-10-02 (outside the repository) |
| Revision | `648676f7c95b82ffc54b7f49612108e0258d2e939a924dd713afa367351f2514` |
| Version | `null` |
| Origin | `Sources/Pisaka/Assets.xcassets/Glyphs` |
| License | ISC AND MIT — `Resources/Licenses/design-glyphs.txt`, the export's `LICENSE.txt` copied verbatim |

**Why the revision is a digest.** The export carries no upstream commit and no
release version: it is a folder of PDFs, a `LICENSE.txt` and a `MANIFEST.txt`
listing each PDF's sha256 prefix and drawn size. The one value that names this
exact set of bytes is therefore the full sha256 of `MANIFEST.txt` itself, and
that is what the acknowledgement records as its revision. There is no version to
name, so the record and the manifest entry both say `null`.

## Glyphs taken

Twenty-four of the export's thirty-two PDFs, each copied byte for byte into
`<name>.imageset/<name>.pdf`. The prefix is the first sixteen hex digits of the
PDF's sha256, as `MANIFEST.txt` lists it; the size is the drawn size in points
the manifest states, which is `DesignGlyph.nativeSize`. The last column says
whether the glyph is one the licence text's MIT notice names (the glyphs derived
from the older set the ISC licence's second section lists); the rest are under
the ISC licence alone.

| Glyph | Prefix | Size | MIT notice |
|---|---|---|---|
| `package` | `9af0fd7e48d454dd` | 11 | no |
| `git-branch` | `e97db149acea601c` | 11 | no |
| `chevron-down` | `dcfc02712d3dc7c1` | 11 | yes |
| `chevron-right` | `e2e0632f1546236b` | 11 | yes |
| `git-pull-request` | `e041f1b4ade4197b` | 11 | no |
| `check` | `19dd2cb3bd997dd5` | 11 | yes |
| `terminal` | `eaf8334dc2314447` | 11 | yes |
| `file-warning` | `ee8267b3b8dfdff0` | 11 | no |
| `git-compare` | `c12e53cfccba2544` | 11 | no |
| `list-checks` | `65983fbf38e0ecf9` | 11 | no |
| `search` | `af5946f6cc73b081` | 11 | yes |
| `git-pull-request-arrow` | `ce4cfcefde81e484` | 11 | no |
| `folder` | `c910b4a14dc215bd` | 12 | no |
| `folder-open` | `bcfb7e66403110fa` | 12 | no |
| `file-code` | `fceaf43b42b4e8a7` | 12 | no |
| `file-text` | `97843a4f65451c00` | 12 | no |
| `database` | `51310c236bbf44f3` | 11 | yes |
| `x` | `4acf054fb35ee278` | 11 | yes |
| `user-round` | `99e687bb2776220c` | 11 | no |
| `undo-2` | `8b51ee486f7d8d75` | 13 | no |
| `refresh-cw` | `310ac9510740d9ec` | 13 | no |
| `case-sensitive` | `317b3d293df0264b` | 14 | no |
| `whole-word` | `690693f0f9dd12b9` | 14 | no |
| `regex` | `c0fd98edaa9f0bd9` | 14 | no |

The eight left behind (`chevron-left`, `circle`, `circle-check`, `circle-dot`,
`circle-x`, `info`, `minus`, `plus`) are not drawn anywhere, so they do not ship.

Every imageset's `Contents.json` sets `"template-rendering-intent": "template"`,
so the glyph is tinted by whatever colour the drawing site hands it, and
`"preserves-vector-representation": true`, so it stays sharp at every interface
scale rather than being rasterised at its 1x size.

## Updating by hand

1. Take the new export's `icons/` folder. Check every PDF you mean to ship
   against its line in the new `MANIFEST.txt` (`shasum -a 256 <name>.pdf`, first
   sixteen hex digits).
2. Copy each PDF over `Sources/Pisaka/Assets.xcassets/Glyphs/<name>.imageset/<name>.pdf`.
   A new glyph gets a new imageset with the same two properties as its
   neighbours, a new `DesignGlyph` case whose raw value is its name, and a row in
   the table above; a dropped glyph loses all three.
3. Update the table's prefix and size columns, and `DesignGlyphAssetTests`'
   pinned prefix table, from the new manifest. A changed size also changes
   `DesignGlyph.nativeSize`.
4. Take `shasum -a 256 MANIFEST.txt` of the new export and write it into the
   `Revision` row above and the `revision` of the `design-glyphs` entry in
   `Resources/Licenses/licenses.json`.
5. Re-copy `LICENSE.txt` verbatim over `Resources/Licenses/design-glyphs.txt`,
   re-check which shipped glyphs its MIT section lists, and update the last
   column above.
6. Run `swift test`: `DesignGlyphAssetTests` and `LicenseCoverageTests` both fail
   until the catalog, this record, the enum and the manifest entry agree.
