# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users

The owner and other Mac users who run local language models through oMLX. The main scene is a long spoken conversation at the desk, with the window open and in view. Quick asks from other apps through the global shortcut and floating orb are a secondary use.

## Product Purpose

Speak to Me turns any chat model served by oMLX into a voice assistant. You speak, it answers out loud, and you can interrupt it mid-sentence just by talking. Success is a conversation that feels natural and is fun enough to come back to.

## Positioning

Speech recognition, the language model and speech synthesis all run on the user's own Mac. Replies start while the model is still writing, and talking over a reply interrupts it without headphones.

## Operating Context

A native window on a Mac desktop, usually kept open during a conversation. Space toggles the mic, M mutes it, C shows or hides the conversation, Esc stops a reply and ⌥Space talks from any app. The language model competes for the same GPU as the interface, so visuals must stay cheap and pause when idle or hidden.

## Capabilities and Constraints

- Phases: loading, ready, listening, hearing, transcribing, thinking, speaking, failed.
- Live microphone and speaker audio are available to the interface.
- Typed messages, muted replies, muted mic, interruption, retry, read aloud and copy.
- Saved conversations, model picker, settings, floating orb and menu bar icon.
- Tools: web search, reading pages, current time, opening apps and web pages, and seeing the screen on request.
- Speech models for several languages, with voice cloning in English and Russian.
- macOS 15 or later on Apple Silicon. SwiftUI and Metal, with shader source compiled at launch so building needs no Metal toolchain.

## Brand Commitments

The name is Speak to Me. The owner has said nothing in the current look is precious, including the orb and palette. The microphone button is explicitly rejected, and starting to talk is done by clicking anywhere in the window or pressing Space. Voice-reactive waves are what the owner enjoys most. The owner wants the app to catch attention and be fun to use.

## Evidence on Hand

README screenshots in `docs/screenshots/`, and the app's `--snapshot` mode. This is an early personal project, run so far on one machine. There are no customers, testimonials or benchmarks to cite.

## Product Principles

- The voice is the interface: what you see should come from the sound actually happening.
- Interrupting is the signature, so it should be felt and not just permitted.
- Every feature stays reachable, but none competes with the conversation.
- Delight must never slow down the model or the reply.

## Accessibility & Inclusion

Every phase must be distinguishable by text as well as by colour and motion, and all controls must stay keyboard reachable. Respect Reduce Motion.
