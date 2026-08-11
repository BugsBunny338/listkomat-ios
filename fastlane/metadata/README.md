# App Store metadata

Source of truth for App Store Connect copy (issue #2 positioning: no sign-up,
no credit, no internet, 10 cities). ASC is still updated manually — paste from
here on each release (or wire up `fastlane deliver` later).

- `cs/` — Czech (primary locale)
- `en-US/` — English (added with the English localization, issue #3)

Constraints: subtitle ≤ 30 chars, keywords ≤ 100 chars (comma-separated, no
spaces needed after commas).
