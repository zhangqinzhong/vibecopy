# Icon Style

VibeCopy's translation island currently uses SF Symbols in the native SwiftUI surface.

Historical changelog entries reference earlier WebUI icon-system experiments. Those notes are preserved as design history, but the current native island should follow these rules:

- Prefer SF Symbols for toolbar and action icons.
- Use a quiet, thin-line appearance with medium optical weight.
- Keep icon color secondary by default, using cyan only for active translation-direction controls.
- Avoid blocky hover backgrounds; feedback should be subtle color or opacity changes.
- Keep the center swap control visually prominent with a circular floating surface.

If custom icons return later, keep each source asset reusable and document the rendering path here before changing runtime code.
