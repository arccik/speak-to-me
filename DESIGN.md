---
name: Speak to Me
description: A local voice assistant whose conversation is cut, live, into one giant record.
colors:
  cherry-vinyl: "#E5102B"
  cobalt-label: "#1420FF"
  acid-reply: "#F4FF3A"
  white-you: "#FFFFFF"
  pale-reply: "#FBFFC2"
  muted-vinyl: "#7A0A1C"
  stuck-vinyl: "#15131A"
  hover-wash: "rgba(255, 255, 255, 0.18)"
typography:
  words-large:
    fontFamily: "Avenir Next, -apple-system"
    fontSize: "34px"
    fontWeight: 800
    letterSpacing: "-0.5px"
  words-medium:
    fontFamily: "Avenir Next, -apple-system"
    fontSize: "26px"
    fontWeight: 700
    letterSpacing: "-0.2px"
  words-small:
    fontFamily: "Avenir Next, -apple-system"
    fontSize: "21px"
    fontWeight: 700
    letterSpacing: "-0.2px"
  status-stamp:
    fontFamily: "Avenir Next Condensed"
    fontSize: "24px"
    fontWeight: 800
  type-field:
    fontFamily: "Avenir Next, -apple-system"
    fontSize: "22px"
    fontWeight: 800
  pane-title:
    fontFamily: "Avenir Next"
    fontSize: "22px"
    fontWeight: 800
  transcript-you:
    fontFamily: "Avenir Next, -apple-system"
    fontSize: "16px"
    fontWeight: 800
  transcript-reply:
    fontFamily: "Avenir Next, -apple-system"
    fontSize: "16px"
    fontWeight: 500
  action:
    fontFamily: "Avenir Next"
    fontSize: "13px"
    fontWeight: 700
  small-print:
    fontFamily: "Avenir Next"
    fontSize: "12px"
    fontWeight: 600
  puck-caption:
    fontFamily: "Avenir Next Condensed"
    fontSize: "13px"
    fontWeight: 800
rounded:
  square: "0px"
  chrome: "6px"
  settings-field: "8px"
  settings-chip: "9999px"
spacing:
  hairline: "4px"
  tight: "6px"
  stack: "12px"
  rhythm: "18px"
  margin: "22px"
  settings-margin: "28px"
components:
  text-action:
    textColor: "{colors.white-you}"
    typography: "{typography.action}"
    rounded: "{rounded.square}"
    padding: "0 6px"
    height: "26px"
  text-action-hover:
    backgroundColor: "{colors.white-you}"
    textColor: "{colors.cherry-vinyl}"
    typography: "{typography.action}"
    rounded: "{rounded.square}"
    padding: "0 6px"
    height: "26px"
  top-icon:
    textColor: "{colors.white-you}"
    width: "28px"
    height: "24px"
  top-icon-hover:
    backgroundColor: "{colors.hover-wash}"
    textColor: "{colors.white-you}"
    rounded: "{rounded.chrome}"
    width: "28px"
    height: "24px"
  composer-toggle:
    textColor: "{colors.white-you}"
    rounded: "{rounded.square}"
    size: "28px"
  composer-toggle-on:
    backgroundColor: "{colors.white-you}"
    textColor: "{colors.cherry-vinyl}"
    rounded: "{rounded.square}"
    size: "28px"
  sleeve:
    backgroundColor: "{colors.cobalt-label}"
    textColor: "{colors.white-you}"
    rounded: "{rounded.square}"
    padding: "14px 22px 16px"
  transcript-you:
    textColor: "{colors.white-you}"
    typography: "{typography.transcript-you}"
    width: "400px"
  transcript-reply:
    textColor: "{colors.pale-reply}"
    typography: "{typography.transcript-reply}"
    width: "480px"
  puck-caption:
    backgroundColor: "{colors.cherry-vinyl}"
    textColor: "{colors.white-you}"
    typography: "{typography.puck-caption}"
    rounded: "{rounded.square}"
    padding: "0 10px"
    height: "20px"
  preset-chip:
    rounded: "{rounded.settings-chip}"
    padding: "0 10px"
    height: "26px"
  preset-chip-selected:
    backgroundColor: "{colors.cherry-vinyl}"
    textColor: "{colors.white-you}"
    rounded: "{rounded.settings-chip}"
    padding: "0 10px"
    height: "26px"
---

# Design System: Speak to Me

## Overview

**Creative North Star: "The Cutting Lathe"**

The window is a single record, seen from directly above, too big for its frame. Everything said in the conversation is physically cut into it: your voice in white, the reply in yellow, spiralling outward from the label as a calendar of what was said. There is nothing to press. Clicking anywhere drops the arm; dragging around the disc scratches back through the talk.

The surface is loud and flat like a pressed sleeve. Colour runs at full strength over the whole window, heavy geometric type is printed straight onto the vinyl, and one colour change from across the room tells you the phase. Density is low on the stage: one status word, the words being said, a line of underlined controls and a line of small print. Depth comes from the record itself, not from interface layers.

The whole of it is driven by one mechanism. Rotation, groove age and a single travelling wavefront account for all stage motion, drawn by one Metal fragment shader, so a long conversation costs the GPU the same as a short one. The world refuses the category's glowing blob and round mic button. Settings is deliberately outside the world: native macOS forms with cherry accents.

**Key Characteristics:**
- Full-strength cherry vinyl bleeding past every edge, with a cobalt label
- White ink for you and yellow ink for the reply, on grooves, words and cartridge alike
- Grooves that start hot and big, then cool and sink back into the vinyl
- One wavefront carrying each change across the whole surface
- Heavy type set directly on the vinyl, with no cards, pills or glass on the stage
- Underlined words as controls, and the whole window as the talk control

## Colors

Three saturated inks at full strength, on a surface that changes colour whole rather than in part.

### Primary
- **Cherry Vinyl** (#E5102B): The record in loading, ready, listening, hearing and speaking. Also the ink on white when a control inverts, the label in thinking and failure, and the accent throughout Settings.

### Secondary
- **Cobalt Label** (#1420FF): The record's label at rest. In transcribing and thinking it swaps with cherry, so the whole vinyl turns cobalt and the label turns cherry. Also the flat ground of the conversation sleeve.

### Tertiary
- **Acid Reply** (#F4FF3A): The reply's ink, in its grooves, its words on the vinyl, and the cartridge while a reply is being cut. Also the spindle dot, which is yellow in every phase.

### Neutral
- **White You** (#FFFFFF): Your ink, and all interface text, icons, the printed label ring and the tonearm.
- **Pale Reply** (#FBFFC2): Long reply text on the sleeve only: the reply's yellow calmed enough to read for a while (7.5:1 on cobalt).
- **Muted Vinyl** (#7A0A1C): The record while the mic is muted, with the arm part lifted.
- **Stuck Vinyl** (#15131A): The record in failure, with a cherry label. The window's only dark state.
- **Hover Wash** (white at 18%): Hover behind icon buttons.

### Phase table

| Status word | Vinyl | Label | Turns a second | Arm |
| --- | --- | --- | --- | --- |
| Warming up, Ready | Cherry | Cobalt | 0 (coasts to a stop) | Parked |
| Listening | Cherry | Cobalt | 0.12 | On the groove |
| Mic muted | Muted Vinyl | Cobalt | 0.06 | Part lifted |
| Hearing you | Cherry | Cobalt | 0.22 | On the groove |
| Thinking | Cobalt | Cherry | 0.1 | Lifted |
| Speaking | Cherry | Cobalt | 0.2 | On the groove |
| Stuck | Stuck Vinyl | Cherry | 0 | Parked |

Every phase also has its status word, so colour and motion are never the only signal. Dragging the disc replaces the word with "Rewinding".

### Named Rules

**The Whole Disc Rule.** A phase colour changes the entire vinyl, never a badge, dot or patch on it. The state should read from across the room.

**The Two Inks Rule.** In grooves, spoken words and the cartridge, white is always you and yellow is always the reply. Yellow never carries interface text on the vinyl.

**The Full Strength Rule.** Words on the vinyl are pure white or pure yellow at full opacity. Yellow on cherry reaches 4.3:1, so it is set at 21pt or larger; white on cherry reaches 4.7:1. The only lowered values are disabled controls (50 to 55%) and the empty type field's prompt (80%, at 22pt). A line you cut off is still drawn at 72% in the build, which falls to 2.7:1 on cherry: that is a defect to fix, not a state to copy.

## Typography

**Display Font:** Avenir Next (with the system face for any other script)
**Body Font:** Avenir Next on the stage; the system face in Settings forms
**Label/Mono Font:** Avenir Next Condensed Heavy for status words and the printed label ring

**Character:** Sleeve lettering: heavy, geometric and slightly tight, printed rather than placed. The condensed stamp beside it reads like a pressing mark.

### Hierarchy
- **Words, large** (heavy, 34pt, -0.5pt tracking, 2pt tighter than natural leading): What is being said now, under 70 characters, and the empty-state invitation.
- **Words, medium** (bold, 26pt, -0.2pt tracking, 1pt extra leading): Lines of 70 to 149 characters, and every system or error message.
- **Words, small** (bold, 21pt, -0.2pt tracking, 1pt extra leading): Lines of 150 characters or more. Height caps at 190pt, newest words at the bottom; lines over 190 characters fade out through the top quarter of that block.
- **Status stamp** (condensed heavy, 24pt): The one word naming the phase.
- **Type field, pane title** (heavy, 22pt): The typed draft on the stage, and each Settings pane's name.
- **Transcript** (16pt): Your lines heavy with 2pt extra leading, reply lines medium with 4pt extra leading.
- **Action** (bold, 13pt): Underlined word controls and mic notices.
- **Small print** (semibold, 12pt): The hint line and tool notes. The model menu and "You cut in here" use the same size in bold.
- **Label ring** (condensed heavy, white, 3 units of kerning at 62 on a 768 unit texture): "SPEAK TO ME · model name", fitted to one lap of the label and spun with it.
- **Puck** (condensed heavy, 13pt caption; semibold, 11pt snippet): The floating record's text.

### Named Rules

**The Whole String Rule.** Avenir Next has no Cyrillic, so any string containing an alphabetic character at or above U+0250 is set entirely in the system face at the same size and weight. Never let Avenir's punctuation mix into another script, and pass the string to the font choice wherever the text is user or model content.

**The Size by Length Rule.** On the vinyl, text size follows length (34, 26, then 21pt) rather than role, so a short answer shouts and a long one still fits.

## Layout

The main window defaults to 520 by 800pt and stops at 440 by 640pt, with a hidden title bar. It is one composition, not a grid. The disc's centre sits at 46% of the height and horizontally centred; the disc bleeds past every edge. The label's radius is 13% of the window's long side, capped at 150pt (104pt at the default size). The first groove starts 14pt outside it, with 9pt between grooves.

Content hangs on a 22pt margin. The top bar is 30pt tall and shares the traffic lights' row, with 76pt reserved at its leading edge. The status word sits 8pt below it. The words sit at the bottom left in a block up to 620pt wide (560pt when empty), with 12pt above the control row, and 16pt of margin below the small print. Controls in a row sit 18pt apart.

Opening the conversation slides the sleeve up from the bottom edge to 130pt from the top. The disc rides up to centre on that edge at half size, half in the sleeve like a record being put away, and the arm fades out. In the transcript, your lines sit right in up to 400pt, replies sit left in up to 480pt, and rows are 18pt apart.

Settings is fixed at 720 by 560pt with a 190pt sidebar and a 28pt header margin. The floating record is a 200 by 230pt transparent panel with a 150pt disc, 3.4pt groove pitch, no arm and no printed label.

## Elevation & Depth

The interface is flat: no cards, panels, blurs or drop shadows on text or controls. Depth belongs to the record. Two fixed wedges of warm light sit across the grooves and stay put while the disc turns, hot grooves glow slightly into the vinyl around them, and the wavefront lifts the grooves and catches the light as it passes. The sleeve is a flat colour field that covers the disc with a hard edge.

### Shadow Vocabulary
- **Tonearm shadow** (black at up to 34%, offset 3 by 5pt, soft over 9pt; offset and softness grow as the arm lifts, to about 2.8 times the offset and 15pt at Thinking's lift): The stage's only shadow. It is computed in the shader, and it is how a lifted arm reads as lifted.
- **App icon tile** (black at 35%, 14pt down, 28pt blur): The icon's standard macOS tile shadow only.

### Named Rules

**The Tonearm Rule.** The arm is the only object that floats above the record. Interface elements stay printed on it.

## Shapes

Two forms carry the system: true circles for the record and square-cornered blocks for everything laid over it. Hover and on states on the stage are hard rectangles, and so are the floating record's caption strips. The tonearm is a thin rod with a round hub and a capsule cartridge. The top bar's icon hover is the one soft corner on the stage (6pt). Settings uses native macOS corners, with 6pt key caps, 8pt text areas and fully rounded personality chips.

## Components

### The Record
The signature component and the only stage graphic: one fragment shader reading a 64-turn window of two-byte groove samples (level and owner).
- **Grooves:** Uncut grooves are hairlines of the vinyl colour at 58% brightness. Cut grooves carry their owner's ink. A groove's heat decays with age over about 9 turns, so its swing and width shrink as it moves outward; it holds full colour for about 6 turns, then sinks to 22% strength by about 19.
- **Voice:** The level comes from the actual mic or speaker signal, over a noise floor, with a fast attack and slow release. Each groove leans 30% on the turn before it, so neighbours nest instead of crossing. Saved or typed lines with no audio are cut from the rhythm of their words.
- **Hush:** Under the words, grooves fall to 20% strength over a 70pt ramp that follows the height of the text.
- **Label:** Printed white ring that spins with the disc, and a yellow spindle.
- **Tonearm:** White rod and hub hanging from the top right, with a hub centre in the label colour. The cartridge is white, or yellow while a reply is being cut. The head jitters very slightly with the voice level.
- **Scratching:** Dragging around the disc rewinds at 6 turns per lap, shows the line under the head, and springs back on release.
- **Cost:** 30 frames a second while active and 20 while idle. It pauses 3 seconds after going idle, and whenever the window is hidden or covered.
- **Reduce Motion:** The disc holds still, grooves step out once a turn, colours change without a wavefront, and level-driven shiver and jitter stop.

**The Hot Groove Rule.** Only the groove being cut stands out. Anything older must cool into the vinyl, so the disc stays calm however long the talk runs.

**The One Front Rule.** One wavefront crosses the disc at a time, at 1400pt a second from the centre, with the new colour inside it and the old one outside. A vinyl or label colour change strikes at full strength, entering hearing or speaking from a calm phase strikes at 0.6, and cutting into a reply strikes at 2.4 with no colour change. Phase changes that alter neither colour nor strike state send nothing.

### Text Action
The standard control on the stage: no box, just the word.
- **Style:** Bold 13pt white, underlined, with an optional 11pt symbol before it. It keeps a 26pt tall hit area.
- **Hover:** A white rectangle behind it, cherry text, underline removed.
- **Disabled:** 55% opacity.
- **Uses:** Type, Conversation with its count, Stop reply, Mute mic, Mute replies, Try again, Hide, Send, Back and the suggested prompts.

**The Word Is the Control Rule.** Stage controls are underlined words. Icon-only buttons are kept to the top bar, the actions under a reply and the composer toggles. Nothing on the stage is a filled or pill-shaped button.

### Whole Window Control
Clicking anywhere on the stage starts or stops talking, with a link pointer and an accessibility button action. Space does the same. Controls sit above this layer, and static text lets clicks through.

**The No Mic Button Rule.** Talking starts from a click on the window or floating record, Space, the global shortcut or the menu bar item, never from a dedicated button in the window. Mute mic is a word, and it appears only once the mic is on.

### Icon Buttons
- **Top bar:** Bold 13pt white symbols in 28 by 24pt. Hover is the wash; disabled is 50%.
- **Reply actions:** Bold 11pt symbols in 24 by 22pt, with a square wash on hover. They show on the latest reply and on hover for older ones. A completed copy flashes a yellow checkmark for 1.2 seconds.
- **Composer toggles:** 28pt square. On is a solid white square with a cherry icon.

### Inputs / Fields
The type field replaces the control row: heavy 22pt white on the vinyl, with no box, sitting on a 2pt solid white rule. The prompt is white at 80%. Return sends and Esc goes back to voice.

### The Sleeve
The conversation as a flat cobalt field that springs up over the record (0.55 seconds, slight bounce). It holds the status word, a Hide action, a scrolling transcript and the same control row. Your lines are heavy white on the right, with words still being heard at 80%; replies are medium pale yellow on the left, with no bubbles. Cut-off replies drop to 82% with a "You cut in here" scissors note; tool and screen notes use small print with a symbol. New rows fade up 12pt in 0.25 seconds, and the transcript fades out over its top 5%.

### Floating Record
A whole small disc on a transparent, always-on-top panel, sharing the main window's engine, so it shows the same grooves. Click starts or stops; dragging moves it. Text can't print on the vinyl here because the desktop sits behind it, so the caption and snippet sit on square strips filled with the current vinyl colour.

### Settings
Native macOS, in the style of System Settings: a sidebar of panes and grouped forms on the system window background, following the system appearance.
- **Sidebar:** Standard list, with every symbol in cherry.
- **Header:** Pane name in heavy 22pt Avenir Next, with a callout line of explanation below in secondary.
- **Controls:** System toggles, sliders, pickers and buttons, tinted cherry. Sliders carry words at each end and the value on the right.
- **Personality chips:** Fully rounded 26pt tall chips, filled cherry with white text when selected. The world's no-pill rule covers the stage, not this pane.

**The Native Settings Rule.** Settings is where the app stops performing. Add the cherry tint and the display-face header, and leave the rest to the system.

### App Icon
The record at rest, on a standard macOS tile (824 units on a 1024 canvas, 186 unit corner): cherry ground, concentric dark grooves, one yellow and one white wave around a cobalt label, and a yellow spindle. Yellow runs outside white.

### Motion
Words change with a fade and a 12pt rise over 0.25 seconds. Status words crossfade over 0.2 seconds, and the control row over 0.18 seconds. Everything on the record comes from rotation, groove age and the wavefront rather than added animation.

## Do's and Don'ts

### Do:
- **Do** derive every moving part of the stage from the record's one mechanism: rotation, groove age and the wavefront.
- **Do** drive grooves from the sound actually happening, in the owner's ink.
- **Do** change state by changing the whole vinyl, and pair it with its status word.
- **Do** set text straight on the vinyl in pure white or yellow, with the grooves hushed behind it.
- **Do** use the system face for the whole string when text contains any non-Latin script.
- **Do** make a new stage control an underlined word (Text Action).
- **Do** keep Settings native, adding only the cherry tint and the pane header.
- **Do** respect Reduce Motion and pause drawing when idle or hidden: the language model needs the GPU.

### Don't:
- **Don't** add a glowing orb or blob, or a round mic button.
- **Don't** put cards, pills or glass on the stage. The floating record's strips exist only because it has no vinyl beneath its text.
- **Don't** add shadows to text or controls. The tonearm's shadow is the record's own.
- **Don't** set yellow text on cherry below 21pt.
- **Don't** dim words on the vinyl to show hierarchy; change size or weight, or move them to the sleeve.
- **Don't** let old grooves stay bright, or add a second concurrent wavefront.
- **Don't** add a button to start talking.
