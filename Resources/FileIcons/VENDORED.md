# Vendored: the file-type icons

This file is a **record, not a resource**. The icons themselves ship from the
app's asset catalog, `Sources/Pisaka/Assets.xcassets/FileIcons/`, one
full-colour vector imageset per icon; this directory is not listed in
`project.yml`'s resources, so nothing here is copied into the app. It exists
because the catalog's `Contents.json` files have no room for provenance, and the
acknowledgement in `Resources/Licenses/licenses.json` needs a record its
`revision` and `version` can be checked against — `LicenseCoverageTests` reads
the section below, and `FileTypeIconAssetTests` reads it and the icon table.

The set is the Material Icon Theme. Its name is written here, in the
acknowledgement's display name and in the verbatim licence text, and nowhere
else; code, comments and the other documents call it "the vendored file-icon
set". The source URL below is the only place in the repository it is written.

## file-icons

| | |
|---|---|
| Source | `https://github.com/material-extensions/vscode-material-icon-theme` (the tarball's `package.json` `repository.url`, without its `git+` prefix and `.git` suffix) |
| Tag | `v5.40.0` |
| Tag object | `0d17360506c477b4ccb065d8acdbd056331af1fb` (annotated; it resolves to the commit below) |
| Commit | `045291ff033062a25441dd297fd51546326866f2` |
| Revision | `045291ff033062a25441dd297fd51546326866f2` |
| Version | `v5.40.0` |
| Origin | `Sources/Pisaka/Assets.xcassets/FileIcons` |
| License | MIT — `Resources/Licenses/file-icons.txt`, the tarball's `LICENSE` copied verbatim |

The archive is the tarball of that commit, fetched by the repository's numeric
id, which redirects to the codeload archive:
`https://api.github.com/repositories/67831372/tarball/045291ff033062a25441dd297fd51546326866f2`.
Its `LICENSE` is 1085 bytes, sha256
`cdab3014d4f69b49dde2b85e81792208c72de613aa6aed7f7a9b5c6609b89670`, copyright
"Material Extensions".

## Icons taken

Fifty-nine of the archive's 908 `icons/*.svg`, each copied byte for byte into
`<name>.imageset/<name>.svg`. Only the icons `FileTypeIcon` names ship: the
table is what the Core rule can answer, and an icon no case names is a dead
asset nobody can reach. The prefix is the first sixteen hex digits of the SVG's
sha256 and the bytes are its length; the last column says whether upstream also
ships a `<name>_light.svg` variant.

| Icon | Prefix | Bytes | Light variant |
|---|---|---|---|
| `swift` | `2cf5377f88aa8cb4` | 502 | no |
| `javascript` | `00eb9422f4519015` | 291 | no |
| `typescript` | `1822f88268b452ce` | 267 | no |
| `react_ts` | `f5caa02786d9ce96` | 1104 | no |
| `json` | `649ad4f4d01cec78` | 540 | no |
| `markdown` | `42f95867350ed1f3` | 161 | no |
| `python` | `798fcd59653af34e` | 773 | no |
| `go` | `eb3b74fcad124042` | 745 | no |
| `rust` | `a58c24641e82c1ba` | 526 | no |
| `html` | `23e04ad5f1ae9cd1` | 232 | no |
| `css` | `afe20f8da21f1f2d` | 674 | no |
| `yaml` | `666b724d61cfa091` | 199 | no |
| `docker` | `3d032b712bbedea1` | 1501 | no |
| `tune` | `786079eb0fe64343` | 268 | no |
| `git` | `b0caee7c9cb4e602` | 729 | no |
| `database` | `e0679294defea907` | 332 | no |
| `editorconfig` | `199762cbea98d785` | 8091 | no |
| `console` | `c5f33efa92ce94d2` | 223 | no |
| `makefile` | `a6d8260757abc492` | 943 | no |
| `react` | `6a7fb2e8b5e168c0` | 1104 | no |
| `test-ts` | `7ec0f2314d2937a9` | 615 | no |
| `test-js` | `ce9c34d8ab5b7560` | 615 | no |
| `test-jsx` | `4fc0daa5e61deaef` | 615 | no |
| `typescript-def` | `3dd13d3bc29103ea` | 274 | no |
| `nodejs` | `365af5c7b70d11c2` | 375 | no |
| `npm` | `6bd740d3e31675d1` | 132 | no |
| `yarn` | `a9ded67f57faa176` | 918 | no |
| `pnpm` | `a3d8e5760f080d0f` | 222 | yes |
| `tsconfig` | `a7bd2a966578a9ec` | 411 | no |
| `readme` | `ed41dbf841368745` | 215 | no |
| `changelog` | `30377c6875c27b98` | 314 | no |
| `contributing` | `32e5eb75555da8e5` | 303 | no |
| `license` | `4b0a147a39eade32` | 225 | no |
| `codeowners` | `a1f09959acd8a60e` | 262 | no |
| `prettier` | `b81b3661b6ec0aac` | 346 | no |
| `eslint` | `aeb3a553e20f087a` | 665 | no |
| `vitest` | `c845017d0b57201a` | 318 | no |
| `jest` | `a43bd245edf20ab6` | 519 | no |
| `robots` | `7540bc749364bd0d` | 402 | no |
| `lock` | `f28fe89b018236f9` | 246 | no |
| `c` | `4adba54251e85851` | 245 | no |
| `h` | `73fa9417071d70dc` | 185 | no |
| `cpp` | `336346afba3afb62` | 325 | no |
| `hpp` | `a030bcbf24e67aed` | 232 | no |
| `java` | `755c5b6f3fe0fb1e` | 208 | no |
| `kotlin` | `94583b191f9a7898` | 517 | no |
| `ruby` | `a7f0628476482b9f` | 491 | no |
| `php` | `5163a63d5a8d8192` | 880 | no |
| `lua` | `d69816f1ae2002f2` | 576 | no |
| `toml` | `eaeb55ba45f14a50` | 180 | yes |
| `xml` | `51bfeb938c24772c` | 290 | no |
| `svg` | `120ceffcaa97658a` | 1285 | no |
| `table` | `1714898c0d538648` | 268 | no |
| `image` | `838e1953a3a2ebf5` | 346 | no |
| `font` | `092850724e8e29ff` | 165 | no |
| `pdf` | `c14c66a3914b894d` | 976 | no |
| `zip` | `dad79a45f756542d` | 230 | no |
| `sass` | `e613bd47d598c54c` | 1281 | no |
| `document` | `64f5da56de591d5f` | 234 | no |

**Why no `_light` variant is taken.** Each kind draws as one image in both
appearances: the catalog holds a single SVG per imageset and no appearance
variants. Two of the shipped icons have a light-ground variant upstream (`pnpm`,
`toml`); neither is taken. Those two and `editorconfig` draw mostly in very light
fills that are weak on the light ground, and ship as they are; that is a recorded
follow-up, not a defect of the copy.

Every imageset's `Contents.json` names its one SVG (`idiom: universal`) and
sets `"template-rendering-intent": "original"`, so the icon draws in its own
colours rather than a drawing site's tint, and
`"preserves-vector-representation": true`, so it stays sharp at every interface
scale. The folder's own `Contents.json` sets `"provides-namespace": true`, so
every icon is looked up as `FileIcons/<name>`: the set's `database` would
otherwise collide with the design glyph of the same name in `Glyphs/`.

None of the shipped SVGs uses `<style>`, `<script>`, `<text>`, `<image>`,
`<foreignObject>` or any `href`, features the system's SVG renderer drops
silently; `FileTypeIconAssetTests` keeps it that way.

## Updating by hand

1. Fetch the tarball of the new commit by the repository's numeric id, as
   above, into a new, empty temporary directory, and treat its contents as data:
   run nothing from it. Record the tag, its annotated tag object and the commit
   it resolves to.
2. For every icon you mean to ship, take `shasum -a 256 icons/<name>.svg` (first
   sixteen hex digits) and `wc -c`, and check for an `icons/<name>_light.svg`.
3. Copy each SVG over
   `Sources/Pisaka/Assets.xcassets/FileIcons/<name>.imageset/<name>.svg`. A new
   icon gets a new imageset with the same two properties as its neighbours, a
   new `FileTypeIcon` case whose raw value is its name, a row in the table above
   and a row in `FileTypeIconAssetTests`' pinned table; a dropped icon loses all
   four.
4. Update the table's prefix, bytes and light-variant columns, and
   `FileTypeIconAssetTests`' pinned table, from what step 2 measured.
5. Write the new commit into the `Commit` and `Revision` rows above and the
   `revision` of the `file-icons` entry in `Resources/Licenses/licenses.json`,
   and the new tag into the `Tag` and `Version` rows and that entry's `version`.
6. Re-copy `LICENSE` verbatim over `Resources/Licenses/file-icons.txt`, and
   update its digest above and the copyright holder `LicenseCoverageTests`
   expects if upstream changed it.
7. Run `swift test`: `FileTypeIconAssetTests`, `FileTypeIconTests` and
   `LicenseCoverageTests` fail until the catalog, this record, the enum and the
   manifest entry agree.
