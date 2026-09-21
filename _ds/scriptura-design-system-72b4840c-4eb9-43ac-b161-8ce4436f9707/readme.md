# Scriptura Design System

> The design system for **Multi-Script Practice** — a handwriting trainer for learners
> studying non-Latin scripts (Burmese, Hindi, Telugu, Japanese, Korean, Chinese).
> "Scriptura" is the working name for the system; the product ships under the
> literal title **Multi-Script Practice**.

---

## What the product is

Multi-Script Practice is a single-page web app that teaches you to **handwrite**
characters across multiple writing systems. You pick a **script family** (Indic or
CJK), then a **language**, then drill through four content levels — Consonants,
Consonant+Vowel, Words, Sentences — each available in four **modes**:

- **Practice** — trace a guide glyph on a drawing canvas, step through the set.
- **Quiz** — shown the romanization/cognate, write the character from memory, reveal & self-grade.
- **Sheet** — a printable grid of cells to fill by hand.
- **Review** — a per-character mastery heatmap and progress stats.

The whole experience is **dark, calm, and glyph-forward**: the characters being
learned are the largest things on screen, sitting on near-black surfaces with a
single vivid accent color per mode.

### Source material

- **Codebase:** `Consonants_writing_app_advanced/` (attached, read-only). Vanilla
  HTML/CSS/JS app. Key files:
  - `index.html` — the full two-level navigation markup.
  - `css/styles.css` — the entire visual system (tokens, layout, components). This
    is the single source of truth this design system is distilled from.
  - `data/languages.js` — character sets per language (Burmese set lifted into the UI kit).
  - `core/canvas.js`, `core/storage.js` — drawing + persistence logic.
  - `Kaizen.txt` — product roadmap notes (C / C+V / Word / Sentence tabs, anchor-word memorisation).
- No Figma file and **no binary assets** were provided — the brand is entirely
  typographic + emoji + native Unicode glyphs (see Iconography).

---

## Content fundamentals

How the product talks:

- **Voice is instructional and encouraging, never chatty.** Short imperative labels:
  "Start Practice", "Done, Next", "Check Answer", "Show Guide", "Reset Progress".
- **Second person, implied.** Prompts address the learner directly — "Write this
  character:", "Your Answer", "Practice Here" — but rarely use the word "you".
- **Title Case for actions and tabs** ("Practice Sheet", "Show Guide"); **UPPERCASE +
  letter-spacing** for small section labels ("SELECT SCRIPT FAMILY", "CORRECT ANSWER").
- **Sentence case for helper hints** ("Write this character:").
- **Numbers are first-class.** Counters ("1 / 33"), counts on tabs, stats (Correct /
  Wrong / Streak), percentages. Keep them tabular and terse.
- **Emoji are part of the copy**, used as compact mode/action icons — one per concept,
  never decorative clusters: ✍️ brand, ✏️ practice, 🧠 quiz, 📝 sheet, 📊 review,
  ✓ correct, ✗ wrong, ↩ undo, 🗑 clear, 👁 reveal, 🔄 reset, 🖨️ print, 🚧 coming-soon.
- **Native script + cognate + romanization travel together** wherever a character is
  shown (e.g. က / क / "ka"). This triad is a core content pattern.
- Vibe: a focused practice tool — supportive, low-noise, progress-driven. No marketing
  fluff, no exclamation-mark hype.

---

## Visual foundations

- **Mood:** deep near-black canvas, vivid functional accents, soft colored glows.
  Premium-dark, focused, a touch playful via the rounded forms and emoji.
- **Color:** four-tier dark surface ramp (`#0a0a0f → #12121a → #1a1a25 → #222230`).
  Text is off-white `#f0f0f5` → lavender-grey `#8888aa` → muted `#555566`. Each
  **mode owns one hue**: practice green `#22c55e`, quiz blue `#3b82f6`, sheet violet
  `#8b5cf6`, review orange `#f97316`. Each **script family** owns one: Indic amber
  `#f59e0b`, CJK pink `#ec4899`. Status: success green, error red.
- **Accents almost always render as a 135° gradient** from the hue to a darker stop
  (`#22c55e → #16a34a`), never flat — on buttons, active tabs, active cards.
- **Type:** one UI family, **Outfit** (300/400/500/600/700). Each writing system has a
  dedicated **Noto Sans** face applied only to native glyphs. Display headline uses a
  **tri-color gradient clipped to text** (green→blue→violet). UI scale runs 0.75–1.5rem;
  glyph scale runs large (tab 1.4rem → main 7rem).
- **Backgrounds:** the homepage sits on an **"aurora"** — three stacked radial-gradients
  (amber / blue / violet at 6–8% alpha) over near-black. App pages are flat near-black.
  No photography, no textures, no patterns.
- **Corners are generously round:** cards & panels 20px, buttons/tabs 12px, tool buttons
  & chips 10px, **language chips are full pills (35px)**, nav buttons are circles.
- **The signature shadow is a colored glow**, not a neutral drop shadow: every accent
  surface casts a soft shadow tinted with its own hue (`0 12px 40px rgba(accent, .4)`).
  Neutral cards use a quiet `0 4px 15px rgba(0,0,0,.2)`; drawing canvases use an *inset*
  shadow so they read as wells.
- **Cards:** `bg-card` fill, 1px `#2a2a3a` hairline border, 20px radius, ~24px padding.
  Selectable cards lift (`translateY(-6px)`) and brighten their border on hover; when
  active they swap to the accent gradient + glow and drop the border.
- **Borders:** a single hairline token `#2a2a3a` used everywhere; accent borders appear
  only on hover/active states and the review heatmap cells.
- **Motion is quick and gentle — fades and small lifts, never bounce.** Default
  `transition: all .2s ease` for taps/hovers, `.3s` for cards/toggles/page fades.
  Two keyframes recur: `fade-in` (opacity + 10px rise) for tab content, `slide-up`
  (opacity + 15px rise) for the revealed quiz answer. No spring, no infinite loops.
- **Hover states:** surfaces lighten one tier (`bg-secondary → bg-elevated`) or brighten
  their border; primary buttons additionally **lift and intensify their glow**; nav
  buttons fill with quiz-blue. **Press/active:** the element adopts its accent fill.
- **Transparency & blur:** sparing. Mastery heatmap cells use ~20–25% alpha accent
  fills; the aurora uses 6–8% alpha. No backdrop-blur / frosted glass anywhere.
- **Light-on-dark inversions:** the **drawing canvas and worksheet cells are light**
  (`#fefefe`) islands inside the dark UI — ink is dark, guide glyphs are faint grey.
- **Layout:** centered columns. Homepage caps at 700px; the practice page caps at
  1400px with a fixed **320px character panel + fluid canvas** two-column grid that
  collapses to one column under 900px. Min hit target 44px.

---

## Iconography

- **There is no icon library, icon font, or SVG sprite** in the product — and none is
  needed. Iconography is delivered three ways:
  1. **Emoji** as functional mode/action glyphs (see the list under Content
     Fundamentals). Use them one-per-concept, inline with the label, at text size.
  2. **Native script characters** (က, あ, 한, 汉, क, క) used as the icon for a script
     family or content tab — rendered in the matching Noto Sans face.
  3. **Unicode arrows & marks** for navigation and tools: ← → ✓ ✗ ↩ … rendered in Outfit.
- **No brand logo file exists.** The logo lockup is **✍️ + a gradient wordmark**
  ("Multi-Script Practice" in Outfit 700 with the tri-color text clip). Recreate it
  with live text + the emoji, never as a raster.
- If a future surface needs line icons beyond emoji, substitute **Lucide** (CDN) at
  ~1.75px stroke to stay close to the friendly-rounded feel — **flagged as a
  substitution**, since the current product ships none.
- **Do not hand-draw SVG icons** for this brand; prefer the emoji + glyph approach above.

---

## Fonts

All faces load from **Google Fonts** (`tokens/fonts.css`) — these are the *real* fonts
the product uses, so there is **no substitution**:

- **Outfit** — all UI text.
- **Noto Sans Myanmar / Devanagari / Telugu / Sinhala / Tamil / JP / KR / SC** — native glyphs per script.

> Note for the compiler: because the fonts arrive via a Google Fonts `@import` (not a
> local `@font-face`), the design-system "Fonts" count reads 0. This is intentional —
> consumers get the live webfonts. If you need self-hosted `.woff2` files, ask and they
> can be vendored with explicit `@font-face` rules.

---

## Index / manifest

> The UI kit was **redesigned** from the source app's two-level tab tool into a
> guided, gamified study flow (dashboard + focused study view, lesson path,
> animated stroke reveal, SRS review, flashcards, word builder, XP/streak/levels,
> theme switch). The token system and components below are unchanged foundations.

Root:
- `styles.css` — global entry point (import manifest only). **Consumers link this.**
- `tokens/` — `fonts.css`, `colors.css`, `typography.css`, `spacing.css`, `effects.css`.
- `readme.md` — this file.
- `SKILL.md` — Agent-Skill front matter for downloading into Claude Code.

`guidelines/` — foundation specimen cards (Design System tab):
- Colors: Surfaces · Text & Borders · Mode Accents · Script & Status · Worksheet & Mastery
- Type: Display Headline · UI Type Scale · Script Fonts · Glyph Scale
- Spacing: Spacing Scale · Radius Scale
- Brand: Logo Lockup · Colored Glows · Aurora Background

`components/` — reusable React primitives (namespace `ScripturaDesignSystem_72b484`):
- `buttons/` — **Button** (primary/secondary/ghost, accent + size), **NavButton** (circular)
- `forms/` — **Toggle**, **RangeSlider**, **SegmentedControl**
- `navigation/` — **Tab** (stacked content tabs + inline mode tabs)
- `data-display/` — **Card**, **Pill** (language chip), **StatChip**
- `progress/` — **ProgressRing** (daily-goal / completion), **XPBar** (level)

`ui_kits/scriptura/` — full interactive recreation, redesigned as a **guided,
gamified Burmese study app**:
- `index.html` — sticky app bar (brand · Home/Path/Review/Build nav · streak ·
  **theme switch: Midnight / Dusk / Daylight**) + routed content; holds global
  state (learned set, XP/level/streak profile, SRS queue).
- Screens: `Dashboard.jsx` (daily-goal ring, streak, level, routing),
  `LessonPath.jsx` (the 6 unit nodes), `LessonView.jsx` (the core
  **Learn → Trace → Quiz** loop, awards XP), `ReviewSession.jsx` (SRS due queue),
  `WordBuilder.jsx` (consonant + vowel-sign → live syllable).
- Kit primitives: `StrokeGlyph.jsx` (animated “watch it form” reveal + replay),
  `Flashcard.jsx` (3D flip, prompt ↔ answer + Burmese letter-name),
  `LessonNode.jsx` (path node with progress ring + status), `DrawCanvas.jsx`
  (functional tracing surface), `data.js` (33 consonants in 6 real teaching units
  with authentic Burmese letter-names, vowel signs, SRS + mastery sample state).

> Generated by the compiler, do not edit: `_ds_bundle.js`, `_ds_manifest.json`,
> `_adherence.oxlintrc.json`.
