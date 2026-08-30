# App Store metadata

Source of truth for App Store Connect copy (issue #2 positioning: no sign-up,
no credit, no internet, 10 cities).

`scripts/asc_new_version.py` pushes these files to ASC on every release, so
**edit them here, never in the ASC web UI** — a web-UI edit is silently
overwritten on the next release. That is how the Czech subtitle and keywords
drifted from this directory before 2.5, back when only `release_notes.txt` was
ever uploaded.

- `cs/` — Czech (primary locale)
- `en-US/` — English (added with the English localization, issue #3)

| file | ASC field | scope |
|------|-----------|-------|
| `release_notes.txt` | What's New | per version |
| `description.txt` | Description | per version |
| `keywords.txt` | Keywords | per version |
| `subtitle.txt` | Subtitle | product page |

Subtitle is product-page copy and is only editable **between** submissions —
while a release is in review the script skips it with a note. Re-run
`asc_new_version.py` after approval to land a subtitle change.

Screenshots are still uploaded by hand.

Constraints (checked by the script before it calls ASC): subtitle ≤ 30 chars,
keywords ≤ 100 chars, description ≤ 4000.

## Writing keywords

The 100 characters are the whole budget, so don't waste them:

- **No spaces after commas** — each one costs a character for nothing.
- **No multi-word phrases.** Apple combines single keywords automatically, so
  `SMS jízdenka` is 12 characters that `sms` and `jízdenka` already cover.
- **Don't repeat the app name or subtitle** — both are already indexed. `sms` is
  dropped from `cs` for exactly this reason: the subtitle is
  "SMS jízdenky bez registrace".
- Case is irrelevant to matching; lower case throughout keeps diffs readable.
