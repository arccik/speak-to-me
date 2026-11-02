---
version: 1
slug: "sources-speaktome-contentview-swift"
primary_target: "Sources/SpeakToMe/ContentView.swift"
related_targets: ["Sources/SpeakToMe/Visuals.swift","Sources/SpeakToMe/FaceEngine.swift","Sources/SpeakToMe/FaceRenderer.swift","Sources/SpeakToMe/MistControls.swift","Sources/SpeakToMe/MiniOrb.swift","Sources/SpeakToMe/SettingsView.swift"]
---

Scope: the main window of Speak to Me, plus the floating face. Mode: Experience. Audience: Mac users having long spoken conversations with a local model at the desk. Task: talk, listen, interrupt. Constraints: every existing feature stays reachable except drag-to-rewind (owner dropped it), GPU stays cheap, pauses when hidden or asleep. Build path: code-led, no image generation available. Owner rejected the cute cloud build as childish and pinned: serious, mysterious, dark, a fair bit creepy.

## Direction contract

THESIS: A wasted, real-looking face emerging from black fog, watching you, speaking. Its lips follow the actual voice; its mouth opens too far on crooked, rotten teeth. It refuses the category's glowing blob, round mic button and friendly avatar.
OWN-WORLD: Near-black cold ground (#07080C), grey fog, bone-grey relief lit from one side, wet bloodshot eyes with milky irises and pinprick pupils in hollow sockets, stained pointed teeth in dark gums. Oxblood dark (#2C060C) for thinking. Bone (#D8CFA8) for reply words, cold white for yours. Didot at display sizes, Avenir Next medium small. Controls are thin wisps of mist, no pills or glass.
STORY: The eyes find your pointer. Click anywhere; your voice closes in as faint ripples. Its eyes roll back under a red dark while thinking, then speaks, cold breath falling from its mouth. Talk over it and it lurches at you, eyes flaring. Left alone it fades away and drawing stops.
FIRST VIEWPORT: Head centred and hanging, dissolving at its edges, with the top-left dark free for the status word in Didot italic. Words 34pt bottom-left. Wisps below. As words grow the head rises and shrinks.
FORM: The Apparition, an owner-pinned steer of The Wind Head. seed:8f5472a16b62176f
Signature interaction: lip sync from three live voice bands; slow eyes that follow the pointer everywhere. Motion grammar: almost still, slow drift; one dark wave leaves the mouth per phase change; only the lurch is fast.
Raises: from Phosphor Terminal, light that lingers. From Cracktro, fog in planes with a still front. From Daylight Section, a single light direction.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
