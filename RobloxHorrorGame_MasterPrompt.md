# MASTER PROMPT — Realistic Hide & Survive Horror Game (Roblox)

> Paste this entire document into Claude Code / Claude Fable 5. Ask it to generate all systems as complete, production-ready ModuleScripts.

---

## 🎯 PROJECT GOAL

Build a **AAA-quality, immersive hide-and-survive horror game** for Roblox. The player should genuinely feel tension, fear, and relief — like they are "living" the game, not just playing a script. Every system must be **realistic**, **detailed**, and **polished**: layered sound design, full animation coverage, dynamic lighting, a large multi-area map, and meaningful player actions/choices. This is not a prototype — treat it as a shippable, polished product.

---

## 🗺️ 1. MAP DESIGN (Large, Multi-Zone Layout)

Build a significantly larger map than a single corridor loop — a full facility/house/complex with **at least 6–8 connected zones**, so pacing and tension can build over a longer playthrough (aim for 5–8 minute rounds, not 3).

Required zones:
1. **Safe Spawn Room** — calm lighting, tutorial prompts, no danger.
2. **Entry Hallway** — introduces sound mechanics, first hiding spots (lockers).
3. **Living/Common Area** — large open room, couches, tables — high risk, low cover, teaches player to avoid open spaces.
4. **Kitchen/Utility Room** — noisy objects (pots, glass) player can knock over accidentally, interactive risk.
5. **Bedroom Wing** — beds to hide under, closets, curtains, most hiding-spot density.
6. **Basement/Maintenance Area** — dark, flickering lights, tight corridors, higher tension, sound is more dangerous (echoes).
7. **Vent/Crawlspace Network** — connects zones, lets skilled players reposition silently but slowly, adds strategic depth.
8. **Exit/Extraction Zone** — secondary win-condition area (reach it after timer, or as an alternate objective), safe once reached.

Map requirements:
- Every zone must connect logically (no isolated dead-end unless it's a deliberate risk/reward hiding spot).
- Include **environmental storytelling** props (knocked-over furniture, blood smears, claw marks) to build atmosphere without a single line of dialogue.
- Include **interactive objects** that create risk/reward: doors that creak when opened fast vs. slow, windows that can be climbed through, breakable glass, noisy floor tiles (creaky wood vs silent carpet).
- Add **at least 12–15 hiding spots total** spread across zones, varying in safety level, entry/exit time, and discovery radius.

---

## 🎮 2. EXPANDED PLAYER ACTIONS (More Than Just Hide)

Beyond walk/run/crouch/hide, add:
- **Peek** — lean around corners/door edges without fully exposing the body (reduced detection risk while checking for danger).
- **Hold Breath** — reduces breathing sound audio cue for ~4 seconds (cooldown after use), useful when enemy is very close.
- **Distraction Throwables** — pick up and throw a bottle/can to create a sound decoy elsewhere in the map.
- **Slow, Silent Door Opening** — hold a key to open doors slowly and silently vs. quick-but-loud.
- **Barricade** — push furniture in front of a door for a temporary block (costs time, very loud).
- **Climb/Vault** — over low obstacles (windows, low walls) for shortcuts, at a stamina cost.
- **Stamina System** — running drains stamina; exhausted players breathe loudly and move slower, creating a real risk/reward loop.
- **Flashlight (optional item)** — helps in dark zones but drastically increases visibility to the enemy.

---

## 🔊 3. REALISTIC, LAYERED SOUND DESIGN

Sound must be a core gameplay mechanic, not a background layer.

### Player-generated audio (spatial, distance-attenuated):
- Footsteps: distinct sound sets per surface (wood creak, tile click, carpet muffle, metal vent clang, wet basement splash) and per movement state (walk/run/crouch/injured limp).
- Breathing: normal / heavy after sprinting / panicked when tension is high / held breath (near-silent).
- Heartbeat: low volume ambient at rest, rising in tempo and volume as the tension meter increases, becomes a dominant audio cue near max danger.
- Clothing/fabric rustle when crouching or exiting hiding spots.
- Contextual sounds: door creaks (variable pitch/volume based on open speed), glass breaking, furniture scraping, vent panel clangs.

### Enemy audio (directional, so players can localize threat by ear):
- Distant ambient growl/breathing that increases in volume/frequency as it nears.
- Distinct footstep pattern (heavier, slower cadence than player) that changes with state (patrol/investigate/hunt).
- A unique "detection stinger" sound the instant the enemy spots the player — sharp, sudden, unmistakable.
- Snarls/vocalizations that vary between investigating (curious, low) and hunting (aggressive, sharp).

### Ambient/environmental layers (mixed at low volume, looping seamlessly):
- Base ambient drone per zone (different tone for basement vs bedroom vs kitchen).
- Random one-shot environmental stingers (distant bang, pipe groan, wind) on unpredictable timers to keep players on edge even when safe.
- Reverb/echo zones: basement and vents should feel acoustically different (more reverb) than carpeted bedrooms (dampened).

### Sound design technical requirements:
- Use Roblox's SoundGroup and 3D spatial sound (RollOff, EmitterSize) so direction and distance are readable.
- Implement audio ducking: when a high-priority stinger plays (detection, jump-scare), briefly lower ambient/music volume.
- All sounds must have volume/pitch randomization (±5-10%) so repeated sounds don't feel robotic.
- Provide a cooldown/anti-spam system per sound category.

---

## 🎬 4. FULL ANIMATION COVERAGE

Every state, for both player and enemy, needs a matching animation — nothing should look static or teleport between poses.

### Player animations:
- Idle (subtle breathing sway), walk, run (with fatigue variant when stamina is low), crouch-walk, hold-breath (tense frozen pose), peek-lean, climb/vault, hiding-enter/exit per hiding-spot type (locker crouch, under-bed crawl, curtain shuffle), hit-reaction/stagger, death/ragdoll on capture, victory relief animation at extraction.
- Smooth blending/transitions between all states (no instant snap); use animation weight blending or the AnimationTrack fade parameters.

### Enemy animations:
- Idle (breathing/head twitch), patrol walk (scanning head movement), investigate walk (slower, cautious, head lowered/sniffing), hunt run (aggressive full sprint), attack lunge/swing, "notice" reaction the instant it spots the player (sudden head-snap + roar), a searching animation when it loses the player (looking around confused), return-to-patrol.
- Body language must visibly communicate state at a glance: hunched/curious in investigate vs. aggressive/upright in hunt.

### Camera & feedback animation layers:
- Camera bob synced to player footstep animation.
- Camera shake tied to enemy proximity/roar events (magnitude scales with tension).
- Smooth FOV kick when sprinting; smooth FOV/blur pull when captured.

---

## 💡 5. LIGHTING & VISUAL ATMOSPHERE

- Full dynamic lighting pass per zone: warm/safe tones in spawn and extraction, neutral in common areas, dim/flickering in basement, moonlit blue tones near windows at night.
- Flickering light script for damaged fixtures (irregular flicker pattern, not a simple sine wave) in tension zones.
- Enemy-proximity lighting response: lights subtly dim or flicker more intensely as the enemy nears, independent of the tension-meter effects already planned.
- Flashlight cone (if implemented) with realistic falloff and shadow-casting.
- Dynamic shadows enabled; ensure hiding spots visibly darken the player model to sell the "hidden" state.
- Subtle particle atmosphere: dust motes in light shafts, fog in the basement, drifting embers or steam near vents — small details that add production polish.

---

## 🧠 6. ENEMY AI — REALISTIC AND ADAPTIVE

Build on the state machine (Idle/Patrol/Investigate/Hunt/Attack) with added realism:
- **Memory system**: enemy remembers last 2–3 known player locations and checks them in sequence when investigating, rather than beelining.
- **Search patterns**: when it loses the player, it performs a believable room-by-room search (checking hiding-spot-adjacent areas first) instead of standing still.
- **Adaptive difficulty (optional)**: enemy gets slightly faster/more persistent if the player is doing very well, to keep tension consistent across playthroughs.
- **Multi-enemy coordination** (if more than one): enemies share investigate locations and spread out rather than clumping.
- Raycast-based line of sight and hearing radius exactly as previously specified, now scaled to the larger map (adjust ranges per zone — tighter hearing radius in open common areas with ambient noise masking, longer in quiet basement).

---

## 📊 7. TENSION & FEEDBACK SYSTEMS

- Tension meter (0–100) driven by: proximity to enemy, enemy state, time spent in open areas, recent near-misses, damage taken.
- Tension directly drives: heartbeat audio, screen vignette darkness, lighting flicker intensity, camera shake magnitude, and ambient music layering (add a subtle music stinger layer that fades in above ~60 tension).
- Near-miss feedback: if the enemy passes within a close radius without detecting the player, trigger a distinct "close call" sound/visual cue (a stronger heartbeat spike + camera flinch) — this is what makes players feel like they're "living" the moment.
- Post-round results screen: survival time, number of close calls, hiding spots used, distance traveled — small stats that make each run feel tracked and personal.

---

## ✅ 8. TECHNICAL & PRODUCTION STANDARDS

- Use ModuleScript architecture with clear separation: GameManager, PlayerController, EnemyAI, AtmosphereSystem, HidingSpotSystem, SoundManager, AnimationController, UISystem, MapManager.
- All tunable values (speeds, ranges, cooldowns, volumes, detection chances) declared as named constants at the top of each script — no magic numbers buried in logic.
- Event-driven communication between modules (BindableEvents/RemoteEvents), not tight coupling.
- Extensive inline comments explaining *why*, not just *what*.
- Basic error handling (pcall around risky calls like animation loading, sound loading) so one missing asset doesn't break the whole game.
- Performance-conscious: pool reusable effects (don't create new Sound/ParticleEmitter instances constantly), disconnect unused connections, use Debris service for cleanup.

---

## 🚀 WHAT TO GENERATE

Please generate complete, working Lua ModuleScripts for every system above, fully integrated via events, with all constants tweakable at the top, extensive comments, and realistic layered audio/animation hooks wired in (asset IDs can be placeholders — structure the code so real animation/sound IDs can be dropped in easily). Prioritize making the experience feel **alive and tense**, not just mechanically correct.
