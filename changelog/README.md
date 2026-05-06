# Changelog

This folder is a human-readable timeline for the VibeCopy vibe, design, and development conversation.

It is not a release changelog. It records product direction, visual references, accepted mockups, implementation notes, and follow-up decisions that shape the app over time.

## Files

- `0000-timeline.md` - the changelog index.
- `YYYY-MM-DD.md` - dated changelog entries. Add new entries to the date file for that day, and create a new date file when the date changes.
- `assets/` - local copies of referenced conversation images and generated design previews.

Do not keep appending all history to one large file. Keep date-specific entries in date-specific files so reviews stay small and readable.

## Image Policy

Images used in the timeline should be copied into `assets/` so the record does not depend on chat history or generated-image cache paths.

Use relative Markdown links:

```md
![Target single panel layout](assets/2026-05-05-target-single-panel-layout.png)
```

## Naming

Use chronological names for timeline assets:

```text
YYYY-MM-DD-short-description.png
```

Example:

```text
2026-05-05-target-single-panel-layout.png
```
