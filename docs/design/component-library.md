# Native component library

| Component | Responsibility |
| --- | --- |
| `StudioHeading`, `StudioEmpty`, `StudioStatus` | Titles and supporting copy, empty states and named session status |
| `WorkspaceNavigation` | Sidebar selection, icon rail and audio configuration sheet |
| `SessionControlBar` | State, meters, Start, Pause, Resume, Stop and audio configuration |
| `WorkspaceView`, `CompactView` | Workspace and auxiliary window compositions |
| `AnswerPane`, `AnswerEntry` | Focus and Chat layouts, format-aware Markdown and revision-specific actions |
| `AnswerViewport` | AppKit clipping and window visibility observation for the first useful answer text |
| `ContextInspector` | Transcript, speaker assignment and learned-context provenance and editing |
| `ProfileEditor`, `ProjectStoryEditor` | Profile library, structured project evidence, status and imports |
| `InterviewReviewView`, `SoloPracticeView` | Retained and in-memory review, practice, coaching and export |
| `ProviderSettingsView` | Category-based settings, model and provider configuration, credential controls and diagnostics |

All app components are in `AppShell`. The shared `WorkspaceModel` owns the active interview reference. Question assembly, provider I/O, context retrieval, attribution, answer revisions and persistence live in `ConversationCore`.

Xcode previews and the special UI verification build use in-memory synthetic fixtures. The production Release excludes the fixture menu, mock transports and test-only capture code.
