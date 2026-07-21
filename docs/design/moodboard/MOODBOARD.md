# Moodboards — chess (MateMate) & LULL

Style reference for agents working in these repos. Two games, one maker, opposite moods — never blend them.
Visual boards: `chess-moodboard.html` / `lull-moodboard.html` (self-contained, open in any browser).

---

## 01 · MateMate (github.com/testtest126/chess)

**Mood:** warm · classical · native-first iOS · quiet craft · one real board, always.
Feels like it shipped with iOS, warmed by the walnut of the classic board.

### Color
- Accent: brass `#8A6216` (light) / gold `#E7BA5C` (dark). Never default iOS blue. (`AccentColor.colorset`)
- Contrast rule (`Styling.swift · BrandCTALabelColor`): labels on gold fill — white in light mode, `#1F1F1F` in dark. White on `#E7BA5C` fails WCAG (<2:1).
- Surfaces: cream `#F6EFE2` / card `#FFFDF8` (light); walnut `#171109` / card `#251C11` (dark). (`WarmBackground.colorset`)
- Outcomes: won `#34C759` · lost `#FF3B30` · draw/ongoing `#8E8E93`.
- Board themes (`BoardTheme.swift`, light/dark squares): Classic `#F0D9B5/#B58763` · Green `#EDEDD1/#759657` · Blue `#DEE5EE/#6B8CAD` · Gray `#E0E0E0/#8C8C91`.

### Type & voice
SF / system only. Large Title 34 heavy · body 17 · row headline 15 semibold + outcome dot · detail 12 `#8E8E93`.
Copy: plain, warm, unhurried. No exclamation marks.

### Rules
- Restyle *within* system idioms: real segmented controls, grouped cards, SF type. No web-look, no fantasy chrome in the app.
- One real board wherever the brand appears (mini boards, position thumbnails, theme tiles).
- Selection = 2px accent ring, offset −1.
- Sign in with Apple: exactly stock, always.
- Motion: default SwiftUI springs only; pieces slide, never bounce. If Settings.app wouldn't animate it, MateMate doesn't.

### Piece design & notation (BoardView.swift · MoveAnnouncer.swift)
- Pieces: Unicode figurines, **filled glyph for both colors**, tinted white(.99) / white(.13) — outline glyphs render inconsistently. Every glyph carries U+FE0E (else the pawn turns emoji and ignores tint). Glyph 0.78× square; dragged piece lifts to 1.4×; white pieces get the stronger shadow (.5 vs .25).
- Board chrome: 14pt continuous corners, soft drop shadow. Coordinates 0.22× semibold, contrast-validated per theme, black halo on dark squares.
- Square states: selected yellow .45 · last move yellow .30 · hint blue .35 · legal target = black .22 dot (ring on captures) · check = red radial glow.
- Notation: SAN from ChessKit (`Board.san`) — `e4 Nf3 exd5 O-O a8=Q Nge2 R1a4 Qxe5+` — always mono on screen. Spoken = built from the move, never raw SAN: "White: Knight to f3, check" / "Black: pawn takes on d5" / "castles kingside" / "pawn promotes to Queen on e1". Every part localized in the app layer.

### Web skins (docs pages only — the iOS app never wears a costume)
Same roles everywhere: ground / bone / gold / jade / flare.
- `arabic` — kufic geometry, indigo + gold. ground `#0d1233`, bone `#ece7d6`, gold `#d4af37`, jade `#4fb0c4`, flare `#c1523f`. Display: Futura.
- `indian` — lac red + marigold, didone. ground `#2a0f14`, bone `#f7ead0`, gold `#e8a020`, jade `#2bb3ad`, flare `#c81d3a`. Display: Didot.
- `andalus` — azulejo + horseshoe geometry. ground `#062a28`, bone `#f0e6d2`, gold `#c9963c`, jade `#2fb3a6`, flare `#c1633f`. Display: Avenir Next.
- `terminal` — CRT phosphor. ground `#080b0a`, bone `#c9d6c9`, gold/merged `#48d06a`, jade `#59d0c0`, flare `#e0574a`. Display: mono.

---

## 02 · LULL (github.com/testtest126/LULL)

**Mood:** cold · minimal · quiet dread · restraint over spectacle · consent, always.
A sleep aid that stops behaving like software. Not a scary game on a phone — the scary thing is the phone. "The unease is in the restraint, not the palette." (`Theme.swift`)

### Color
- App (`Theme.swift`): ink `#07080a` · bone `#d7d5d0` · dim `#82858c` · faint `#494c53` · red `#bb3b3b`.
- Landing (`docs/index.html`): ink `#090c12` · bone `#d9d2c4` · sepia `#b9a179` · cyan `#7f9aa2` · red `#a8433f`.
- Icon ember: `#c0322c`.
- Red appears in exactly one place at a time (REC dot, ember ring, a verdict). Two reds on screen is a bug.

### Type
- LABEL: caption2 mono, uppercase, tracking .1–.32em (e.g. `● WATCHING`).
- TITLE: system 44 heavy, lowercase ("it is awake.").
- BODY: system 17 — honest consent copy, plain, never altered for atmosphere.
- NARRATION: serif, lowercase, two-breath lines, never a shout.

### Voice (Atmosphere.swift — original prose in each register, never a quotation; no author's name on screen)
- Kafka — the threshold (seekingConsent, denied): "a file is opening in your name."
- Beckett — the lull (watching, released): "nothing yet. / that is the idea."
- Poe — the watch (noticing → awake): "the eye has found you / and will not blink."
- Bulgakov — the guest (throughline, curdles): "manuscripts, they say, don't burn. / neither, it turns out, do i."

### Structure & motion
- Phases (`EyeSession.Phase`): dormant → seekingConsent → watching (40s) → noticing (30s) → awake; endings: denied / released (panic switch, honored from any phase).
- One narration line per 9s beat (`Atmosphere.beatSeconds`). Slow crossfades only, never cuts. Escalation = more stillness, not more motion (2+ beats at awake → paralysis pairing).
- Status bar on every screen: phase left, `CLOSE THE EYE` right.
- Consent UI: hairline strokes, no fills; default is deny; declining is always safe and says so.

### Named mechanics — not yet built (docs/concept.md; same pattern: gate → phase machine → voice)
- **THE ROOM** (`Sensor.microphone`) — "the microphone hears the silence, and what breaks it." Nothing recorded, nothing leaves the device.
- **THE REACH** (`Sensor.notifications`) — a notification at 3am, while the app is closed; the one mechanic that reaches past the session. Opt-in.
- **THE PULSE** (`Sensor.haptics`) — a heartbeat in your palm that is not quite yours; dread state drives one shared haptic curve.
- **THE HOUR** (ambient: time + `Sensor.motion` stillness) — "it plays differently when it is late and the room has gone still." No new permission; 03:33 is a different game than 21:00.
- **BEHIND YOU** (spatial audio) — "something placed just over your shoulder, in sound alone." A position, not a creature — never shown, never confirmed.
- New mechanics are new readings of already-granted sensors — never a reason to ask for a new one.

### Ideation art (docs/ideation/ — design notes, not commitments)
Mood-anchor images are tonal references — the ceiling, not the target. Never reproduced literally. No new sensors; same consent gate and panic switch as THE EYE.
- **THE MIRROR** (`mirror-and-still-here.md`) — a surface that should show you yourself, lying. Ladder: clear → lag → drift → independence → contact (ceiling). Reflection = player's own live feed, desaturated + contrast-crushed, behind a growing frame-delay buffer; anything past drift is a canned authored asset caught on look-back, never live generation. Motif: "I AM STILL HERE" — persistent utterance that infects existing Poe copy; fogged, half-wiped, under-shown; full scrawl once at the ceiling, if at all. One true silence before the ceiling.
- **THE IDOL** (`the-idol-and-kintsugi.md`) — beauty quietly breaking, not gore; she is never made whole, she is made *more finished*. Ladder (on EyeSession.Phase): clear → hairline → spreading → gold-bleed → eyes open (ceiling). Cracks = hand-authored vector masks revealed in layers (no fracture sim); gold renders additive — light escaping, not paint. Each *return* of attention advances a crack. The orb = a gilded, distorted read of the player's own camera feed — she is holding you. The gold never resets: the repair IS the haunting. A porcelain tick per crack; silence before the eyes open. Cracks stay material — glass, ceramic, stone — never flesh.

### The one rule — horror by permission (PILLARS.md)
✓ consent explicit, explained, revocable per sensor · ✓ panic switch instant from any phase · ✓ dread over gore · ✓ the game may lie to its fiction, never to the player about what the app does.
✕ photos/contacts/location/health — forbidden forever (no `Sensor` case exists) · ✕ fake "data leaked" · ✕ PII anywhere · ✕ jump-scare cadence, blood, a raised voice.

If a scare only works by breaking this, the scare is wrong — not the rule.
