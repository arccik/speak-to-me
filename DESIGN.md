---
name: Speak to Me
description: A local voice assistant that speaks through a wasted face hanging in black fog.
colors:
  void: "#07080C"
  oxblood: "#2C060C"
  hollow: "#040406"
  you-ink: "#E9ECF1"
  reply-ink: "#D8CFA8"
  reply-long: "#D8D2BC"
  fog: "#8C96A8"
  mist: "#A9B2C2"
  wisp-rest: "rgba(169, 178, 194, 0.17)"
  wisp-firm: "rgba(169, 178, 194, 0.3)"
  flesh-lit: "#A89E8C"
  flesh-bruised: "#78696B"
  enamel: "#BDAB78"
  rot: "#664721"
  gum: "#330A0D"
  vein: "#751412"
  milk-iris: "#B3BDB8"
  cherry: "#B5122A"
typography:
  words-large:
    fontFamily: "Didot, ui-serif, serif"
    fontSize: "34px"
    fontWeight: 400
  words-medium:
    fontFamily: "Didot, ui-serif, serif"
    fontSize: "26px"
    fontWeight: 400
  words-small:
    fontFamily: "Didot, ui-serif, serif"
    fontSize: "21px"
    fontWeight: 400
  status-stamp:
    fontFamily: "Didot-Italic, Didot, serif"
    fontSize: "24px"
    fontWeight: 400
  type-field:
    fontFamily: "Didot, ui-serif, serif"
    fontSize: "22px"
    fontWeight: 400
  pane-title:
    fontFamily: "Didot, ui-serif, serif"
    fontSize: "22px"
    fontWeight: 400
  transcript:
    fontFamily: "Avenir Next, -apple-system, sans-serif"
    fontSize: "16px"
    fontWeight: 500
  error-line:
    fontFamily: "Avenir Next, -apple-system, sans-serif"
    fontSize: "14px"
    fontWeight: 500
  action:
    fontFamily: "Avenir Next, -apple-system, sans-serif"
    fontSize: "13px"
    fontWeight: 500
  small-print:
    fontFamily: "Avenir Next, -apple-system, sans-serif"
    fontSize: "12px"
    fontWeight: 500
  puck-caption:
    fontFamily: "Didot-Italic, Didot, serif"
    fontSize: "13px"
    fontWeight: 400
  puck-snippet:
    fontFamily: "Avenir Next, -apple-system, sans-serif"
    fontSize: "11px"
    fontWeight: 500
rounded:
  key-cap: "6px"
  settings-field: "8px"
  settings-chip: "9999px"
spacing:
  status-drop: "8px"
  dock-stack: "11px"
  bottom: "16px"
  rhythm: "18px"
  margin: "22px"
  prompt-gap: "24px"
  action-gap: "26px"
  settings-margin: "28px"
components:
  wisp-action:
    backgroundColor: "{colors.wisp-rest}"
    textColor: "{colors.you-ink}"
    typography: "{typography.action}"
    padding: "0 6px"
    height: "26px"
  wisp-action-hover:
    backgroundColor: "{colors.wisp-firm}"
    textColor: "{colors.you-ink}"
    typography: "{typography.action}"
    padding: "0 6px"
    height: "26px"
  top-icon:
    textColor: "{colors.you-ink}"
    width: "28px"
    height: "24px"
  top-icon-hover:
    backgroundColor: "{colors.wisp-firm}"
    textColor: "{colors.you-ink}"
    width: "28px"
    height: "24px"
  reply-action:
    textColor: "{colors.you-ink}"
    width: "24px"
    height: "22px"
  reply-action-hover:
    backgroundColor: "{colors.wisp-firm}"
    textColor: "{colors.you-ink}"
    width: "24px"
    height: "22px"
  composer-toggle:
    textColor: "{colors.you-ink}"
    size: "28px"
  composer-toggle-on:
    backgroundColor: "{colors.wisp-firm}"
    textColor: "{colors.you-ink}"
    size: "28px"
  type-field:
    backgroundColor: "{colors.wisp-firm}"
    textColor: "{colors.you-ink}"
    typography: "{typography.type-field}"
    padding: "8px 10px"
  fog-bank:
    backgroundColor: "{colors.void}"
    textColor: "{colors.you-ink}"
    padding: "14px 22px 16px"
  transcript-you:
    textColor: "{colors.you-ink}"
    typography: "{typography.transcript}"
    width: "400px"
  transcript-reply:
    textColor: "{colors.reply-long}"
    typography: "{typography.transcript}"
    width: "480px"
  puck-caption:
    backgroundColor: "{colors.wisp-firm}"
    textColor: "{colors.you-ink}"
    typography: "{typography.puck-caption}"
    padding: "0 8px"
    height: "20px"
  preset-chip:
    rounded: "{rounded.settings-chip}"
    padding: "0 10px"
    height: "26px"
  preset-chip-selected:
    backgroundColor: "{colors.cherry}"
    textColor: "#FFFFFF"
    rounded: "{rounded.settings-chip}"
    padding: "0 10px"
    height: "26px"
---

# Design System: Speak to Me

## Overview

**Creative North Star: "The Apparition"**

The window is a cold black room with something in it. A wasted, real-looking head hangs in fog, lit from one side so that half of it is lost, dissolving at its edges and slightly askew. Its eyes find your pointer and follow it slowly. When it speaks, its lips move with the voice you are actually hearing, and the mouth opens further than a jaw should on crooked, stained, partly missing teeth.

Density is low. There is one status word in Didot italic, the words being said in Didot, and a few controls that are only thin wisps of mist with a word in them. Colour barely exists: near-black ground, grey fog, bone relief, and blood only in the flesh and in the red dark of Thinking. The register is serious, mysterious and creepy, and the owner has rejected a cute version as childish.

The stage is almost still, then rarely violent. Everything drifts slowly, one dark wave leaves the mouth when the phase changes, and the head only moves fast in the lurch when you cut in. All of it is one Metal fragment shader reading one noise texture, so a long conversation costs the GPU the same as a short one, and drawing stops when the window is hidden or the face has dozed off. Settings is deliberately outside this world: native macOS forms with a cherry tint.

**Key Characteristics:**
- A near-black ground that changes whole, turning oxblood while it thinks
- A head of bone-grey relief, lit from one side, dissolving into fog at its edges
- Lips and ripples driven only by live audio
- Wet, bloodshot, milky eyes that look through the fog and follow the pointer anywhere on screen
- Didot for large words, Avenir Next medium for small ones, cold white for you and bone for the reply
- Controls as thin wisps of mist, with no pills, glass or hard edges, and the whole window as the talk control

## Colors

A cold near-black with almost no chroma, where the only warmth is bone and the only red is flesh.

### Primary
- **Void** (#07080C): The ground in loading, ready, listening, hearing and speaking, and the opaque fill of the conversation's fog bank.
- **Oxblood** (#2C060C): The whole dark while transcribing or thinking. It is the one ground colour that reads from across the room.

### Secondary
- **Reply Bone** (#D8CFA8): The reply's words and ripples. Also transcript error lines and the copied checkmark (12.8:1 on Void, 11.8:1 on Oxblood).
- **Long Reply Bone** (#D8D2BC): Reply text in the conversation, slightly less yellow for reading at length (13.2:1 on Void).

### Tertiary
- **Flesh Lit** (#A89E8C) and **Flesh Bruised** (#78696B): The skin, blended by slow blotches and multiplied by the light. They are shader materials, never interface colours.
- **Enamel** (#BDAB78) and **Rot** (#664721): The two ends of a tooth, chosen per tooth.
- **Gum** (#330A0D) and **Vein** (#751412): Dark gums, and the blood in the whites of the eyes.
- **Milk Iris** (#B3BDB8): The clouded iris around a pinprick pupil.

### Neutral
- **Cold White** (#E9ECF1): Your words and ripples, and all interface text and symbols (16.9:1 on Void). It is deliberately not pure white.
- **Hollow** (#040406): The ground when the mic is muted or the app is stuck. It is nearly indistinguishable from Void by colour, so those two states read from the face and the status word.
- **Fog** (#8C96A8): The haze, the veil across the face, the wave's faint crest and the breath, all in the shader.
- **Mist** (#A9B2C2): The colour of the control wisps. Rest is 17% (Wisp Rest), and firm is 30% (Wisp Firm). Both are masked by baked noise, so those are peaks, not flat fills.
- **Cherry** (#B5122A): The Settings tint only, on sidebar symbols, system controls and the selected chip.

### Phase table

| Status word | Dark | Eyes | Look | Frames a second |
| --- | --- | --- | --- | --- |
| Warming up | Void | Shut | Sunk well back, ignores the pointer | 15 |
| Ready | Void | Open | Faintest smile, lips just parted, teeth showing | 15 |
| Listening | Void | Slightly wide | Brows a little up | 30 |
| Mic muted | Hollow | A third open | One brow up, sunk back | 30 |
| Hearing you | Void | Wide | Brows up, slight tilt | 30 |
| Thinking | Oxblood | Rolled back | One brow up, sunk back | 15 |
| Speaking | Void | Open | Follows the pointer at 60%, lips on the voice | 30 |
| Stuck | Hollow | Nearly shut | Brows drooped, ignores the pointer, light at 55% | 15 |

Every phase has its status word, so colour and motion are never the only signal.

### Named Rules

**The Whole Dark Rule.** A phase colour changes the entire ground, never a badge, dot or patch on it. The conversation's fog bank stays Void, so with it open only the band above the bank changes and the status word carries the phase.

**The Two Voices Rule.** Cold white is you and bone is the reply, in words and ripples alike. System messages on the stage are cold white. Bone's only other uses are transcript errors and the copied checkmark.

**The Cherry Stays Out Rule.** Cherry belongs to Settings. The stage's reds are flesh and the oxblood dark, and interface elements on the stage never use them.

## Typography

**Display Font:** Didot, as Didot-Italic for the status word
**Body Font:** Avenir Next, medium
**Label/Mono Font:** None

**Character:** A high-contrast inscription over a plain, quiet sans. The large words read like something carved for the occasion, and the small ones stay out of the way.

### Hierarchy
- **Words, large** (Didot regular, 34pt, 2pt extra leading, or 1pt on the empty-state invitation): What is being said now, under 70 characters, and the invitation.
- **Words, medium** (Didot regular, 26pt, 2pt extra leading): Lines of 70 to 149 characters, and every system or error message.
- **Words, small** (Didot regular, 21pt, 2pt extra leading): Lines of 150 characters or more. Height caps at 190pt with the newest words at the bottom, and lines over 190 characters fade out through the top quarter of that block.
- **Status stamp** (Didot italic, 24pt): The one word naming the phase.
- **Type field, pane title** (Didot regular, 22pt): The typed draft on the stage, and each Settings pane's name.
- **Transcript** (Avenir Next medium, 16pt): Your lines with 2pt extra leading, reply lines with 4pt. Your lines differ from replies by colour and side, not weight.
- **Error line** (Avenir Next medium, 14pt): Transcript errors, with a warning symbol.
- **Action** (Avenir Next medium, 13pt): Words in wisps, and mic notices.
- **Small print** (Avenir Next medium, 12pt): The hint line, tool notes, "You cut in here" and the model menu.
- **Puck** (Didot italic, 13pt caption; Avenir Next medium, 11pt snippet): The floating face's text.

### Named Rules

**The Inscription Rule.** Set by size: 21pt and up is Didot, below that is Avenir Next medium. The italic stamp is the one exception, and it stays in its two places, at 24pt on the stage and 13pt on the puck's backed mist.

**The Whole String Rule.** Didot and Avenir Next are Latin only, so any string containing an alphabetic character at or above U+0250 falls back whole to the system face at the same size, serif at 21pt and up. Never let their punctuation mix into another script, and pass the string to the font choice wherever the text is user or model content.

**The Size by Length Rule.** On the stage, text size follows length (34, 26, then 21pt) rather than role, so a short answer is an inscription and a long one still fits.

## Layout

The main window defaults to 520 by 800pt and stops at 440 by 640pt, with a hidden title bar. It is one composition, not a grid. The head hangs horizontally centred, 478 units tall, at up to 1 unit per point at the default width and at most 1.45. It takes the room between 44pt from the top and 12pt above the words, placed 42% of the way down the spare space. As the words block grows from 130 to 300pt the head draws back to 78% as well as rising, easing into place rather than snapping.

Content hangs on a 22pt margin. The top bar is 30pt tall and shares the traffic lights' row, with 76pt reserved at its leading edge and 10pt at its trailing edge. The status word sits 8pt below it, in the free dark at top left. The words sit at the bottom left in a block up to 620pt wide (560pt when empty), 18pt above the dock, with 16pt below the small print. The dock is inset a further 6pt and holds its action row 11pt above the hint. Wisps in a row sit 26pt apart, and suggested prompts 24pt.

Opening the conversation brings the fog bank up from the bottom edge to 170pt from the top. The head shrinks to fit the band above it, centred, 134pt tall from 36pt down, and still talks; its ripples fade out as it shrinks. Your lines sit right in up to 400pt, replies sit left in up to 480pt, and rows are 18pt apart.

Settings is fixed at 720 by 560pt with a 190pt sidebar and a 28pt header margin. The floating face is a 200 by 230pt transparent panel with a 150pt head and its text below.

## Elevation & Depth

There are no drop shadows, cards, blur panels or glass anywhere on the stage. Depth comes from fog in planes, painted back to front: the dark, haze thickening towards the bottom, the head, a veil of fog drifting across the face, voice ripples that thin out as they reach it, the eyes, and the falling breath. Each plane drifts at its own slow speed, so the room has depth while almost nothing moves. Interface text sits on top, and the dark calms behind it: ripples, breath and the wave's crest fall to 20% over a 70pt ramp above the words and to 12% behind the top bar, and the haze falls by about half. The head's own relief comes from a normal-lit height field, with sockets, nostrils and throat falling away into real dark.

### Named Rules

**The One Side Rule.** The key light comes from the upper left and leaves the far half of the face in shadow. The only other light is a faint cold fill from below, so the shadows never go quite flat. Never add a second key or a rim.

**The Eyes Look Through Rule.** The eyes are drawn in front of the fog and the ripples. Whatever else the fog hides, it never covers the gaze.

**The Dissolving Edge Rule.** The head has no outline. It ends where its height falls into the noise, and while thinking or dozing it sinks back, to a little over half its opacity at the most.

## Shapes

The stage has no corners and no drawn containers. Its forms are organic: a slightly askew head, lips that taper to points with a dip at the centre, teeth that come to points or snap off, and irregular wisps that trail off in strands. Ripples are the one geometric form, evenly spaced around the mouth, and even they bend with the voice's loudness. The fog bank's top edge is a soft fade over 3% of its height. Settings uses native macOS corners, with 6pt key caps, 8pt text areas and fully rounded personality chips.

## Components

### The Apparition
The signature component and the only stage graphic: one fragment shader, a 256-square tiling noise and a two-channel sound history.
- **Lips:** Three live bands of the reply's voice drive them. Loudness opens the jaw, the balance of low to middle frequencies rounds or stretches the lips against this voice's own average, and a hiss closes the jaw by up to 65%. The jaw opens fast and closes a little slower. The upper lip barely moves.
- **Mouth:** Thin cracked lips around wet flesh, a black throat, a tongue lying low and dark gums. Teeth stay the same size however far it opens, so the lips reveal them. Each is its own length and lean, and about one in eight is missing and about one in three snapped.
- **Eyes:** Hollow sockets, heavy lids, bloodshot whites, a milky iris and a pinprick pupil. Gaze eases slowly to the pointer anywhere on screen, or to random glances once the pointer has been still for 20 seconds. Blinks come every 4 to 11 seconds, and on most phase changes. While thinking they roll back.
- **Breath:** Cold mist falling from the mouth, only as strong as the voice. Stage only.
- **Ripples:** Voices disturb the fog at 30% strength, 42 units apart, carrying about four seconds of sound. The reply's move out from the mouth in bone and yours close in on it in cold white. Stage only.
- **The lurch:** Talking over a reply throws the head about 10% towards you, flares the eyes, lifts the brows and shuts the mouth, and it settles over about a second. It comes with the strongest wave.
- **Dozing off:** After 40 seconds in Ready with nobody around, the eyes close and the head sinks back, and at 45 seconds drawing stops. Loading and Stuck stop at 45 seconds without that fade. The pointer wakes it.
- **Cost:** 30 frames a second while listening, hearing or speaking, and 15 otherwise. It also pauses whenever the window is hidden or covered.
- **Reduce Motion:** The fog holds still and the tilt and bob stop, with no ripples, waves, breath or lurch. Lips, blinks and gaze keep working, because they carry meaning.

**The Real Voice Rule.** Lips and ripples come from the sound actually happening, never from a canned loop or the text. With no audio, the mouth rests and the fog stays quiet.

**The One Wave Rule.** A phase change sends one dark wave from the mouth at 1400pt a second, with the new dark inside and the old outside and a soft 52pt edge. A change of ground strikes at full strength, entering hearing or speaking at 0.6, and cutting in at 2.4 with no change of colour. A new wave replaces the last.

### Wisp Action
The standard control on the stage: a word in a thin wisp of mist.
- **Style:** Avenir Next medium 13pt cold white, with an optional 11pt symbol before it, in a 26pt tall hit area. The wisp spills 22 by 13pt past the control, at 17%, and drifts by a couple of points.
- **Hover:** The wisp condenses to a tighter, firmer puff at 30%, scaled 4% larger, over 0.22 seconds.
- **Click:** Three wisps scatter outward and thin away over 0.55 seconds.
- **Disabled:** 55% opacity (4.9:1 on its wisp).
- **Uses:** Type, Conversation with its count, Stop reply, Mute mic, Mute replies, Try again, Hide, Send, Back and the suggested prompts. The dock shows the one side action that matters right now.

**The Mist Control Rule.** Stage controls are words in mist, with no fill, border or edge you could trace. Hovering makes the mist thicken, and nothing else about the word changes.

### Whole Window Control
Clicking anywhere on the stage starts or stops talking, with a link pointer and an accessibility button action. Space does the same. Controls sit above this layer, and static text lets clicks through.

**The No Mic Button Rule.** Talking starts from a click on the window or floating face, Space, the global shortcut or the menu bar item, never from a dedicated button in the window. Mute mic is a word, and it appears only once the mic is on.

### Icon Buttons
Bare until you reach them, then a puff of mist.
- **Top bar:** Bold 13pt symbols in 28 by 24pt, with a firm puff on hover. Disabled is 50%.
- **Reply actions:** Bold 11pt symbols in 24 by 22pt, with a firm puff on hover. They show on the latest reply and on hover for older ones. A completed copy flashes a bone checkmark for 1.2 seconds.
- **Composer toggles:** 28pt square, with the symbol at 55% at rest. Hover is a puff at 70% strength with a full symbol, and on is the full firm puff.

### Model Menu
Small print with a small chevron in the top bar, truncated in the middle at 190pt. It has no box and no hover state, and opens a native menu.

### Inputs / Fields
The type field replaces the action row: Didot 22pt cold white on a firm puff that spills 12pt, up to four lines. The prompt is cold white at 70% (5.6:1 on the puff). Return sends and Esc goes back to voice. Clicking away from an empty field also goes back.

### The Fog Bank
The conversation, rolling up as a bank of Void over the lower window (0.55 second spring, slight bounce), with a soft top edge. It holds the status word, a Hide wisp, a scrolling transcript and the same dock. There are no bubbles. Your lines are cold white on the right, with words still being heard at 80%. Replies are long bone on the left, and cut-off replies drop to 82% (9:1) with a "You cut in here" scissors note. Tool and screen notes use small print with a symbol. New rows fade up 12pt in 0.25 seconds, and the transcript fades out over its top 5%.

### Floating Face
The head alone on a transparent, always-on-top panel with no window shadow, sharing the main window's engine, so it says the same things. Its edges dissolve into the desktop rather than into a dark. Click starts or stops, dragging moves it, and right-click opens a menu. Light text can't sit on an unknown desktop, so the caption and the 2-line snippet of the last 90 characters sit on firm mist with a darkened mist layer behind.

### Settings
Native macOS, in the style of System Settings: a sidebar of panes and grouped forms on the system window background, following the system appearance.
- **Sidebar:** Standard list, with every symbol in cherry.
- **Header:** Pane name in Didot 22pt, with a callout line of explanation below in secondary.
- **Controls:** System toggles, sliders, pickers and buttons, tinted cherry.
- **Personality chips:** Fully rounded 26pt tall chips, filled cherry with white text when selected, and primary at 7% otherwise. The no-pill stance covers the stage, not this pane.

**The Native Settings Rule.** Settings is where the app stops performing. Add the cherry tint and the Didot header, and leave the rest to the system. The past-conversations popover and the menus stay native too.

### Motion
Slow easing and small distances throughout the interface. Words change with a fade and a 12pt rise over 0.25 seconds, status words crossfade over 0.2 seconds, and the action row over 0.18 seconds. Everything on the head comes from the engine rather than added animation.

## Do's and Don'ts

### Do:
- **Do** drive lips and ripples from the sound actually happening, in the owner's ink.
- **Do** change state by changing the whole dark or the face, and pair it with its status word.
- **Do** keep the head real, askew and lit from one side, dissolving at its edges.
- **Do** set stage text straight on the dark, with the fog calmed behind it.
- **Do** make a new stage control a word in a wisp of mist.
- **Do** use the system face for the whole string when text contains any non-Latin script.
- **Do** keep Settings native, adding only the cherry tint and the Didot pane header.
- **Do** respect Reduce Motion and stop drawing when idle or hidden: the language model needs the GPU.

### Don't:
- **Don't** add a glowing orb or blob, a friendly avatar, or a round mic button.
- **Don't** make it cute or cartoonish: the owner rejected the cloud as childish.
- **Don't** put cards, pills, glass or hard-edged containers on the stage.
- **Don't** add shadows to text or controls.
- **Don't** use cherry on the stage, or set interface elements in the flesh reds.
- **Don't** set roman Didot below 21pt.
- **Don't** add a second key light, or a second concurrent wave.
- **Don't** make the head or the fog move fast: besides the voice-driven lips and blinks, only the lurch and the wave are quick.
- **Don't** add a button to start talking.
