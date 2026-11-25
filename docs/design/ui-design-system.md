# Native UI design system

Mock Interview uses system type, SF Symbols and native window and keyboard behavior. The main workspace prioritizes reading and controls the session from a persistent bar. Compact uses the same rendering and action components in a narrower window.

| Role | Light | Dark and system behavior |
| --- | --- | --- |
| Canvas | `#F7F8FA` | Deep blue-gray workspace background |
| Surface | White | A lighter neutral for controls and reading surfaces |
| Elevated | Tinted near-white | Raised chrome and contextual controls |
| Primary, secondary, muted | Blue-black with progressively quieter tones | Light foregrounds with a hierarchy independent of accent color |
| Accent, focus and selection | Indigo, based on `#4263EB` | Lighter indigo, native focus rings and a semantic rail selection fill |
| Success, warning, error | Green, warm amber, red | Legible semantic variants with text and symbol labels |
| Separator | Very light blue-gray | Low contrast separators for changes in region |

`Studio` defines adaptive NSColors and shared spacing at 4, 8, 12, 16, 24 and 32 points. App Appearance respects System, Light or Dark. Native title bars, text fields and menus inherit the selected scheme. Typography uses the system title, headline, body, callout and caption styles. An adjustable answer body with line spacing and a limited reading measure supports scanning at a glance.

Focus and selection stay visible while using native lists, segmented mode controls and standard shortcuts. Every icon-only control has an accessible name and help text. Status dots, warning colors and meter colors accompany text. Selectable answer content can be copied without activating the enclosing control.
