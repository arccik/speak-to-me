---
version: 1
slug: "sources-speaktome-settingsview-swift"
primary_target: "Sources/SpeakToMe/SettingsView.swift"
related_targets: ["Sources/SpeakToMe/SettingsTools.swift"]
---

Mode: Operate. Native macOS settings for first-time and returning users of a local voice assistant. Preserve system controls, appearance, the cherry tint and Didot pane headers.

The user asked for clearer design and navigation across all categories, with related settings together. Provide a Start Here page, task-oriented category names, grouped navigation, searchable topic keywords, and short descriptions. Keep advanced details in disclosure groups without dropping existing controls or permission information. Save changes immediately and restore the last selected category.

Window: 900 × 680pt. Sidebar: 230pt with all category names visible. Detail: 28pt header margin, 24pt Didot title and system grouped forms. Support keyboard navigation and search, both system appearances, descriptive slider accessibility values, and selected preset traits.

Validation: `swift build`; `SpeakToMe --settings-snapshot <dir>` captures all 11 categories in light and dark appearance, two search-result cases and no results. Reviewed at shipping size, including sidebar label fit and fixed header alignment for empty search. Reference screenshots are in docs/screenshots/settings-overview.png, settings-voice.png and settings-cloning.png.
