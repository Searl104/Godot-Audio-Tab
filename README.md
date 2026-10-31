# Audio Workstation for Godot 4.7+ (developed against 4.8 beta) (interface phase, v0.9.1: automation)

An **Audio** main-screen tab for designing sound effects: layer clips on a free grid,
give each clip (and the master) an effect chain, and shape any parameter with Bezier
automation curves. This is the interface only. Nothing is audible yet (see TODO(logic)).

## Install
Copy `addons/audio_workstation` into your project, then enable **Audio Workstation** under
Project > Project Settings > Plugins. An **Audio** tab appears next to 2D / 3D / Script.
The included `project.godot` is a ready-to-open test project with demo content.

## Layout (from the sketch)
    toolbar: File, Edit, Undo/Redo, transport, clock, Snap, Export WAV
    Clips | Curves   (curve bar in curve mode: owner, LFOs, Show All)
    [rows] [ timeline: clip grid, with the curves drawn over it ] [scroll] [dots | value axis]
           [ scrollbar with scale handles                         ] [Fit]
    |Master|chains|+|  Clips | Low Pass | Reverb | [+]

## Timing model
Each clip has its own clock, called **clip time**, which is time in its audio. The clip's curves,
fades and length all live on that clock, so a key always sits on the same moment of the sound.

Pitch is playback rate. When the pitch drops, the audio plays slower, the clip lasts longer on the
timeline, and the clip's curve playhead moves slower to match. For example, at −12 semitones
1 s of audio takes 2 s. Trims, splits and fades work from the waveform you see, so the cut lands
on the sound under the cursor. The Master chain runs on project time.

## Controls
**Clip grid**
- Drag a clip to move it in time and across rows; all selected clips move together.
- Drag a clip's left or right edge to trim. Trimming the left edge also moves the source offset,
  and the clip's curves shift with it, so every key stays on the same moment of the sound.
  Keys trimmed out of view are kept, so trimming back out brings them back.
- Drag the small squares at a clip's top corners to set fades.
- Drag on empty space to box-select. Click empty space to deselect and move the playhead.
- Shift adds to the selection, Ctrl toggles. Hold Alt while dragging to ignore snap.
- Drop audio files from the FileSystem dock. Several files land on consecutive rows.
- Right-click for Split, Duplicate, Mute and Delete.
- Keys: S splits at the playhead, Ctrl+D duplicates, Del deletes, Ctrl+A selects all, Esc deselects, F fits.
- Wheel scrolls rows, Alt+wheel changes the row height, Ctrl+wheel zooms time, Shift+wheel scrolls time.
- Ruler: the top strip edits the loop region; click or drag below it to seek.

**Clip mode and curve mode (0.18)**
The curves are a layer over the clip grid, on the same timeline (project time), using the
grid's whole height for the value axis. **Tab** or the **Clips / Curves** switch above the ruler
changes mode, and opening a curve (its dot on a card, Make Curve, an LFO, or the LFO list)
switches to curve mode on its own; nothing switches back without you.
- Clip mode: the grid is edited. The curves are drawn faintly and ignore the mouse; the eye
  button hides them (remembered per user).
- Curve mode: the grid fades back and can't be clicked; the curves are edited. The value axis and
  the curve list (coloured dots) appear on the right, and the curve bar above the ruler holds the
  Chain / Clip curves switch, LFOs and Show All.
- Which curves: a clip's own curves (Gain, Pitch, Pan) over that clip, stretched with Pitch as it
  plays; a shared chain's curves over the focused clip, with faint copies over the chain's other
  clips (editing one edits them all); Master curves over the whole sound.
- The Clip Time / Project Time toggle and the separate curve pane are gone.

**Navigation (0.18, both modes, on the active layer)**
- Middle-drag pans time and rows (values in curve mode).
- Shift+middle-drag zooms around the point you pressed (since 0.19.2): right zooms time in, down makes
  rows taller (in curve mode: a closer value range). The moment and row under the press stay put, the
  pointer hides while you drag and comes back on that spot, and moving back to the start undoes it.
- Scrollbars on both axes: drag the thumb to scroll, drag either end of it to zoom that axis (the
  other end stays put), double-click it to fit that axis. So a mouse without a middle button or a
  trackpad can do everything.
- **Fit** (the square where the scrollbars meet, or F) fits both axes; in curve mode F also resets
  the value zoom. Time zoom and scroll are shared by both modes; the vertical axis is per mode.
- Curve mode wheel: wheel scrolls values, Alt+wheel zooms them, Ctrl+wheel zooms time.

**Curve layer** (controls follow Godot's Bezier editor)
- Click a key to select it; drag to move. Shift locks an axis, Alt ignores snap.
- Drag the handles of selected keys. Handle modes are Free, Linear, Balanced and Mirrored (right-click).
- Double-click or Ctrl+click adds a key to the active curve, or to the curve under the mouse.
- Drag on empty space to box-select keys. Del deletes, Ctrl+A selects all, F fits.
- Right-click also offers Smooth and Ease (flat handles), plus Solo, Mute and Remove for the curve under the mouse.
- **Scales**: each curve fills the graph's height on its parameter's natural scale. Frequencies
  (Hz) use a log scale (equal space per octave). Decibels use a mixing-fader scale (more room
  near 0 dB). Everything else is linear. Keys are stored on that scale, so a straight line between
  two keys is an even change to the ear, such as a filter sweep that moves evenly through octaves.
  Frequency sliders on the cards are logarithmic too.
- **Value axis** (right edge): shows the selected curve's range in real units, on that curve's
  scale. Hz uses decades (20, 50, 100 … 1k … 20k), dB crowds toward 0, and pitch uses octaves first
  (0, ±12, ±24). The unit sits above the axis, the grid lines follow the ticks, and the selected
  key's exact value is tagged on the axis while you drag. Ticks thin out when the graph is short.

**LFO** (right-click a curve, its dot, or its parameter row › LFO…)
- A panel docks beside the graph with Shape (sine, triangle, square, saw, random), Max, Min,
  Freq, Fade In and Fade Out. Slider drags preview live and undo as one step.
- Between its start and end (the whole clip by default) the parameter swings between Min and Max.
  Fade In and Fade Out blend from the drawn curve into the LFO and back out. The drawn curve stays
  visible as a faint line and its keys stay editable.
- The swing uses the curve's scale (a cutoff LFO swings evenly in octaves). Freq runs on the
  clip's clock, so it slows when Pitch drops. An LFO on Pitch itself changes the clip's timing.
- While the panel is open, the graph shows the Max/Min lines and an "LFO depth" strip with the
  fades, and the axis tags the Max/Min values. Dots of curves with an LFO carry a wave mark, and the
  card's parameter row reads "lfo".
- Trims and splits keep the LFO on the same moments of the sound. If the LFO reaches the clip's
  end, a right trim keeps it reaching the end.
- **Bake to Keys** replaces the LFO with ordinary keys (16 per cycle, with sharp edges for square,
  saw and random). **Remove LFO** removes it. On/Off keeps the settings.

**Dots**: one colour per curve, in the dot column and on each parameter.
- Click cycles **On / Dim / Off**. Dim curves are drawn faint and can't be edited; Off curves are hidden.
- Shift+click solos the curve.
- Right-click offers Select, On/Dim/Off, Solo, Mute, Show All and Remove Curve.
- A grey outline means the parameter has no curve. It has a slider and a field instead; right-click it and choose **Make Curve**.

**Effect chain**
- Master / Clip tabs switch between the master chain and the selected clip's chain. The curve layer follows the active tab.
- Cards are processed left to right. Drag a card's header onto another card to reorder.
- The ⋮ menu on each card offers Move, Reset and Remove. The toggle on the card bypasses it. The + card adds an effect.
- The first card is the fixed source stage: **Clip** (Gain, Pitch, Pan) or **Output** (Volume).
  Pitch is applied as playback rate, so it changes the clip's length too.

Global keys: Space play/pause, Enter stop, Home go to start, L loop, G snap on/off, Ctrl+S save.

## Code map
    plugin.gd                       registers the tab
    core/aw_project.gd              saved document (clips, master chain, loop), demo content
    core/aw_clip.gd                 grid block: time, row, trim, fades, its own chain
    core/aw_clip_warp.gd            clip time <-> project time through the playback rate (pitch)
    core/aw_chain.gd                effects + curves; automation keys live in an Animation (Bezier tracks)
    core/aw_effect.gd, aw_effect_library.gd   effect cards; parameter keys = real AudioEffect property names
    core/aw_lfo.gd                  LFO settings, waveform and fade envelope
    core/aw_curve.gd, aw_curve_math.gd        curve metadata (colour, On/Dim/Off, handle modes, scale),
                                              handle and scale maths
    core/aw_document.gd             selection, view state, and every undoable edit
    core/aw_engine.gd               ENGINE BOUNDARY: finds the native AWCore class, falls back to stubs
    extension/                      C++ GDExtension source (godot-cpp 10.0.0-stable, SCons); see BUILDING.md
    bin/ (after build)              libawengine.<platform>... + aw_engine.gdextension next to plugin.cfg
    core/aw_time_view.gd            zoom/scroll for one time axis
    ui/aw_lfo_panel.gd              the docked LFO panel
    ui/aw_curve_axis.gd             value axis + tick generation (linear / log / fader / semitones)
    ui/*                            toolbar, timeline (clip grid + curve layer, scale bars), effect cards, main screen

## Native engine (milestones 1 to 4)
The plugin looks for the `AWCore` class at startup. With the library built, the toolbar shows
`● Engine 0.6.0`; without it, `○ Engine not built` (or `Engine X is out of date` if the library is older
than the plugin: rebuild it) and everything except sound still works. Build steps: `BUILDING.md`.

**Dry playback (milestone 2).** Play, Stop, seek, loop and double-click audition now make sound.
- `AWSourceCache` decodes files with Godot's own decoders (WAV, Ogg, MP3, imported resources, or raw files
  by path) and hands stereo frames at the audio mix rate to the core.
- `AWEngine` builds a plan of clip voices from the project (start, offset, length, fades, static Gain and
  Pan, pitch as a playback-rate table) and an `AudioStreamPlayer` plays the core through `AWPreviewStream`.
  The playhead is the real playback position; the sound stops by itself at its end (or loops).
- Waveforms in the clip grid are real peaks of the source file (clips with no audio keep the placeholder).
- Export (milestone 5) is done: see "Export" below. Not yet: save/open (6). Clips without an audio file stay silent but still move the playhead.
- The decoder lag of Godot's resampler (about 2 source frames) is removed, so a source sample lands on
  the exact frame the timing model says.
- **Automation (milestone 3).** The Gain, Pan and Pitch curves of a clip (including their LFOs) and the
  Output volume curve are audible. Each is sampled every 64 frames (about 1.5 ms) into a table; the mixer
  interpolates it per sample. Clip curves run on the clip's own clock, so they slow down with Pitch; the Output
  curve runs on project time. Square LFO edges become 1.5 ms ramps (no clicks). A value at the bottom of a dB
  range (-60 dB) is true silence. Tables are cached per curve and rebuilt only when its keys, LFO or the clip
  length change, so dragging a key or an LFO slider re-samples just that curve.
  Sampling is native (`AWCore.sample_curve`, a C++ port of `AWChain.sample`; the self-test compares it with the
  GDScript version on every scale, LFO shape and unit). It also draws the curve graph and builds the pitch
  warp. Eight layered 20 s clips with 24 curves, all with 20 Hz LFOs: plan rebuild 61 ms (it was 8.9 s in GDScript);
  an LFO edit re-samples one curve in about 7 ms.
  Edits while playing are heard within 50 ms.
- **Effects (milestone 4).** Effect cards run in the native engine, in chain order after the Clip card (per clip)
  and after Output (master): Low Pass, High Pass, Band Pass, EQ (6 bands), Amplify, Distortion, Delay, Compressor,
  Limiter, Reverb, Chorus, Phaser, Stereo Enhance and Gate (engine 0.6.0). The DSP is our own, built to fit the
  engine rather than matching Godot's effects. Reverb is a Freeverb-style network (8 damped combs and 4 allpasses
  per side); Chorus has three modulated voices; Phaser six allpass stages; Stereo Enhance works on mid/side (Width
  scales the side, Time delays it, Surround adds a 10 ms inverted cross-feed, so check it in mono); Gate is a
  stereo-linked gate with attack, hold, release and hysteresis, no look-ahead.
  - Parameters come from the same curve tables as Gain/Pan, updated every 32 frames; a curve or LFO on a cutoff
    sweeps the filter. Clip chains read their curves on the clip's own clock; the master chain on project time.
  - Tails and the end marker: the orange **end marker** on the timeline sets where the exported sound ends, so one
    marker sets both the length and the tail. Drag its flag on a ruler, or type a time in the Export dock's End
    field. Chains that ring on (filters, EQ) keep sounding after their clip until the marker; a marker before the
    last clip cuts the sound short. **Auto** (the default, dashed marker) puts it at the last clip's end, plus 2.5 s
    when a ringing card is in a chain. Bypassed cards are left out.
  - Filter memory carries across audio blocks and is cleared on a seek or loop wrap, so the first moments after a
    jump start from silence (a short pre-roll is possible later).
  - Resonance maps to Q: 0.35 at 0, 0.707 (flat) at 0.5, about 14 at 1.
- Interpolation is 4-point cubic; pitching up does not anti-alias yet.
- Alt+wheel over the clip grid changes the row height (default 48 px), so waveforms can be made larger.

## Placeholders (search for TODO(logic))
- `AWEngine`: `render_wav` and `render_audio_stream` are stubs (milestone 5).
- Without the native engine, waveforms are a fake pattern (`AWEngine.get_waveform_peaks`) and
  `AWDocument.tick_preview` is a fallback clock that moves the playhead.
- Save and Open only post a status message.

## Verified
- Tested on Godot 4.7 stable: all scripts parse and the plugin loads without errors.
- An automated run inside the rendered editor passed 135 checks. It covered model edits with undo/redo, and real
  mouse events on the controls: clip move/trim/fade, box-select, multi-move, key move, handle drag,
  key insert, the dot cycle, Make Curve and slider drags. It also checks that curves keep their values at the same
  moments after a left trim, and that scales round-trip and a straight log-scale line gives an even sweep.
  The playback-rate timing is checked against the exact formula, and splits and trims are checked on
  a pitched clip.
- Not covered: drag-and-drop from the FileSystem dock, card reordering by drag, popup menus clicked by a person.

## Open points for the logic phase
- A per-curve scale toggle (e.g. linear vs log) is planned. The scale is already stored per
  curve, and `AWChain.set_curve_scale()` converts the keys; it only needs a UI control.
- Curve keys are stored as 0..1 on the curve's scale. The engine should read real values with
  `AWChain.sample()`, never the raw Animation track.
- `AWChain.sample()` already includes the LFO. The engine needs nothing extra, as long as it
  samples curves often enough for a 20 Hz LFO (≥ 200 Hz control rate is plenty).
- The timing contract for the engine is written at the top of `AWEngine.set_project()`. Evaluate
  clip curves at `clip.project_to_local(t)`, and play the audio at rate 2^(pitch/12).
- Undo and Redo are toolbar buttons. Ctrl+Z from this tab is not wired or tested.
- Projects save as `.tres`/`.res`. A custom `.sfx`-style extension needs a ResourceFormatSaver/Loader.
- The reserved column is a placeholder.

## Effect panels and the control kit (v0.11)

Effects can have a custom detail panel. It opens in the **Audio Effect** dock (bottom by default; double-click a card's header or use ⋮ > Open Panel). Every effect has one, shown compactly on its card (a small plot plus knobs); Chorus, Phaser and Stereo Enhance are knobs only. Gate and Compressor have a draggable threshold, Limiter a ceiling; Reverb shows its RT60. The generic parameter rows remain as the fallback for an effect with no panel.

Curves are not limited to the clip: keys can sit anywhere up to one hour, so a tail (or anything past the clip) can be shaped. A new curve or LFO still spans the clip, the graph frames the clip or, when later, the end marker, and beyond the last key a curve holds its value.

- `ui/kit/aw_binding.gd`: `AWParamBinding` is the only thing a control uses to edit a parameter (undo, live preview, curve dot state, right-click menu, one undo step for multi-parameter drags).
- `ui/kit/`: `AWKnob` (optional bipolar and view range), `AWResponsePlot` (log-frequency plot with draggable handles). Gestures: drag, Shift = fine, wheel, double-click = reset, right-click = curve options. A driven parameter shows a yellow dotted ring and a click selects its curve.
- `ui/kit/aw_panel_registry.gd`: effect type to panel. To add one, subclass `AWEffectPanel` (`ui/panels/`), register it there.
- `core/aw_filter_response.gd`: the drawn response mirrors the engine's biquads; the self-test compares it with the engine's measured output.

The LFO editor is its own **Audio LFO** dock, a single column that suits a tall side dock (lower right by default; it also works at the bottom). It has a waveform preview, shape buttons and knobs for Freq (0.05 to 100 Hz), **Accel** (frequency drift, ±1000 dHz/s (tenths of a hertz per second, so ±100 Hz/s), fine near zero; negative slows down and stops at 0 Hz), Max, Min, **Attack, Decay, Sustain, Release** and **Smoothing** (shapes each envelope segment). Since 0.13 (engine 0.9.0):
- **Absolute / Relative:** Absolute swings between Max and Min, replacing the drawn curve while it runs. Relative wobbles
  ±**Depth** (a share of the parameter's range) around the drawn curve, so a falling pitch curve keeps falling with
  vibrato on top. The curve graph shows the ±Depth band.
- **Phase:** where the cycle starts (0 to 360°).
- **Jitter / Jit Depth:** each cycle gets a slightly different length or height (repeatable for the seed), so the
  movement sounds less mechanical.
- **Seed** (a field under the shape buttons, with **New** for a fresh one): the random pattern for the Random shape
  and Jitter; the same seed always gives the same pattern.
- **Glide:** softens the jumps of Square, Saw and Random; at 100% Square becomes a sine and Random a smooth drift.
- **ADSR (0.17, engine 0.12.0):** the LFO's strength follows an envelope over its span. Attack rises from the drawn
  curve to the full swing, Decay falls to the **Sustain** level (Sustain 0% dies away into the drawn curve: springs,
  settling objects), and Release fades out over the last part of the span. Older sounds convert: Fade In becomes
  Attack, Fade Out becomes Release, and an old half-life Decay becomes a Decay to 0% Sustain of four times its length.
  Sounds saved by 0.17 use format 7.

Sounds saved by 0.13 use format 3; older versions refuse them rather than dropping these settings. Beside them, **All LFOs** lists every LFO in the project as `Clip 2\Low Pass\Cutoff` (Master first); click one to select its clip and open it. The **LFOs** button in the curve bar (curve mode) brings the dock up. Needs engine 0.4.2 or newer (the engine evaluates Accel and Smoothing natively).

Knob gestures: drag, Shift = fine, wheel, **double-click to type a value** (`2k` works, Enter applies, Esc cancels), **Ctrl+click to reset**, right-click for options.


## Export (milestone 5, engine 0.8.0)

The **Audio Export** dock bakes the whole sound (every clip, clip and master chains, up to the end marker) to a file.
- **Automatic file name (0.19.4):** with the file field left empty, the export goes next to the saved sound and is
  named after it (`res://sfx/door_slam.tres` exports `res://sfx/door_slam.wav`); an unsaved sound uses its title.
  The field shows that name as a hint; type a path to choose your own.
- **Anywhere on disk (0.17):** Browse can pick a folder outside this project, for example another game's project.
  Paths inside `res://` are saved relative to the project; others are saved as absolute paths.
- **Formats:** WAV (16-bit with TPDF dither, or 32-bit float) and Ogg Vorbis (variable bit rate, Quality 0 to 10 on
  oggenc's scale; 5 is about 160 kbit/s). For a compressed WAV use Godot's own QOA option when you import the WAV.
- **Same as the preview:** the export renders with the same native code as playback, on its own engine instance, so
  playback and editing carry on. A test checks a 32-bit export equals the preview render sample for sample.
- **Progress and cancel:** one-second chunks with progress; the button turns into Cancel. The file is written as
  `name.part` and renamed when complete, so a cancelled or failed export never leaves a broken file or damages an
  existing one. The editor then imports (or re-imports) the file straight away, so you hear the new export.
- **Report:** length, size, peak level, and a warning with the count of samples over full scale (WAV 16-bit and Ogg
  clip them; lower the Output volume or add a Limiter).
- Ogg encoding uses vendored libogg 1.3.5 and libvorbis 1.3.7 (BSD, `extension/thirdparty/`). Needs engine 0.8.0 or newer.


## Effect chains (0.16)

Effect chains are shared: a chain is a named set of effects (with their curves) that any number of clips play
through, so a group of layers can share one Reverb, and editing it once changes them all. A clip without a chain
plays dry.

- **Tabs** above the cards: `|Master|Impact FX|Debris FX| + |`. **+** makes a new chain for the selected clips (or
  the group) and opens it. Right-click a chain tab: Rename, Duplicate, Use for Selected Clips, Delete (its clips play
  dry; undoable). Selecting a clip opens its chain's tab; a clip without one gets a temporary "· no chain" tab with
  its Clip card and **New Chain** / **Use Chain**.
- The first card of a chain is **Clips**: one entry per clip on the chain, each with its own **Gain, Pitch and Pan**
  knobs (they belong to the clip, not the chain). Click a name to select the clip; × takes it off the chain.
- A chain's curves run on each clip's own clock (a fade-in curve fades every clip in from its own start). The curve
  view's **Chain curves / Clip curves** switch shows the chain's curves or the selected clip's own Gain, Pitch and Pan
  curves; making a curve from a clip's knob switches to it.
- Right-click a clip > **Effect Chain** > New Chain / None / any chain.
- Older sounds open with each clip's effects moved into a chain named "<clip> FX" (the sound doesn't change).
  Sounds saved by 0.16 use format 6.

**Layout:** the narrow reserved column left of the timeline and the "Timeline" titles are gone, as is the overview
strip. The top toolbar has edit shortcuts: Marker (Shift+M), Trim start / end to playhead (Q / W), Reverse, Crossfade
Overlaps and Group / Ungroup (Ctrl+G).

## Timing and navigation (0.15, engine 0.11.0)

- **Snap targets:** the Snap menu (toolbar) holds the time grid (ms steps, or 24 / 30 / 60 fps for syncing with
  animation) and, under "Also snap to", **Clip Edges**, **Playhead**, **Markers** (on by default) and **Transients**
  (off by default; ticks show on the clips while it's on). Targets attract within 8 pixels and win over the grid; a
  guide line shows what a dragged clip snapped to. Both ends of a moved clip snap. Alt drags freely. Remembered.
- **Transients** are found in each sound file (sharp rises above the recent level), so a layer's attack can be lined up
  with another's.
- **Markers:** Shift+M adds one at the playhead (M mutes the selected clips since 0.19.5); Ctrl+Left / Ctrl+Right jump between them. On the ruler: drag to move,
  double-click to rename, right-click to delete or add one there. They show as dashed lines on the grid.
- **Exported WAVs carry the markers as named cue points, and the loop region (when Loop is on) as a sampler loop** that
  Godot's WAV import picks up with Loop Mode "Detect From WAV". (Ogg files have neither.)
- **Ruler:** click moves the playhead; **drag scrubs** (since 0.17: short grains of the sound at its normal pitch
  follow the mouse in either direction, silent when you hold still); **Shift+drag selects a time range**. Dragging on the loop strip at the top
  sets the loop's start and end; its edges still adjust it.
- **Time selection:** right-click the ruler for Loop Selection, Split Clips at Selection, Delete Inside Selection (cuts
  the clips at the edges and removes the parts inside; nothing moves), Zoom to Selection, Clear. Delete with no clips
  selected removes the audio inside; Esc clears it.
- **Navigation:** Z zooms to the time selection or the selected clips (the zoom slider was replaced by scale
  handles on the scrollbars in 0.18); hovering a
  clip shows its file, length, gain, pitch, pan, offset, fades and chain.

Sounds saved by 0.15 use format 5 (markers).

## Filter card and Edit in Audio Tab (0.20, engine 0.14.0)

- **Filter card** (+ menu > Filter): one card for every filter shape, replacing Low Pass, High Pass and Band Pass.
  - **Type** drop-down: Low Pass, High Pass, Band Pass, Notch, Low Shelf, High Shelf, Peak.
  - **Cutoff** and **Resonance** (for shelves and peak, Resonance is the Q).
  - **Slope** (pass and notch types): a continuous 6 to 48 dB/oct knob that can be automated. The engine runs a
    one-pole stage and four biquads and blends between the depths either side of the setting, so a sweep is smooth.
    The first stage takes the resonance; band pass and notch start at 12 dB/oct.
  - **Gain** (shelves and peak): -24 to +24 dB.
  - The panel draws the exact response (checked against the engine for every type and blended slopes); drag its
    handle for cutoff and resonance, or gain for shelves and peak.
  - Sounds saved before 0.20 open with their Low / High / Band Pass cards turned into Filter cards of that type at
    12 dB/oct (the same sound), curves included. Sounds saved by 0.20 use format 9.
- **Edit in Audio Tab**: right-click a sound file in the FileSystem dock. It starts a new, unsaved sound with that
  file as a clip at 0 s, named after it (after asking about unsaved changes), and switches to the Audio tab. The
  automatic export name never overwrites the source file (it becomes `name_edit.wav` when they'd clash).

## Groups (0.19, engine 0.13.0)

A group is a **frame on the grid**: a time span over one or more rows. Every clip that **starts** inside
the span on one of its rows belongs to it, live: drop a clip in and it joins, drag it out and it leaves.
Frames never overlap.
- **Strip** (the header above the group's first row; it adds a little space there, so no clip is covered):
  drag it to move the group with its clips; drag its ends to set the time span; click it to select the
  group (its clips). Buttons: ▾ collapse, **M** mute, **S** solo (both apply to the export). Right-click:
  Rename, Group Colour, Mute, Solo, Collapse, the group chain, Ungroup. Clicking a clip selects just
  that clip, so you can edit inside a group freely.
- **Rows handle** (the small ▼ grip in the frame's bottom-left corner): drag down to take in more rows,
  up to give them back.
- **Collapse** folds the group's rows to thin lanes; the clips still play.
- **Group chain** (strip menu > New Group Chain): a **bus**. The group's clips are mixed first, then the chain
  runs once on the mix, before the Master: one reverb tail, one compressor reacting to the whole group. It
  appears as a "▣ name" tab in the chain panel; its curves run on the group's clock (0 = the group's start,
  so they move with it).
- Ctrl+G frames the selection; Ctrl+Shift+G removes the group (the clips stay). Sounds saved by 0.14 to 0.18
  used group ids on clips; they open as frames around those clips. Sounds saved by 0.19 use format 8.

## Grid editing (0.14, engine 0.10.0)

| Do | How |
|---|---|
| Copy / cut / paste | Ctrl+C / Ctrl+X / Ctrl+V. Pastes at the playhead on the rows the clips came from; works after opening another sound. |
| Nudge | Arrow keys: Left/Right by one snap step (10 ms with snap off), Shift = 10 steps, Up/Down = one row. Hold to repeat. |
| Trim to playhead | Q trims the start, W the end of the selected clips under the playhead. |
| Rename | F2, double-click the clip's name strip, or right-click > Rename. |
| Colour | Right-click > Colour (applies to the selection). |
| Clip gain | Ctrl + drag up/down on a clip (Shift = fine). On a selection, every clip changes by the same amount. Ctrl+click still toggles the selection. |
| Slip | Ctrl+Alt + drag: slides the audio inside the clip; the clip, its fades and curves stay. |
| Reverse | Right-click > Reverse: the same part of the file plays backwards (◂ on the clip). Trims and splits keep working as you'd expect. |
| Fade shapes | Right-click > Fade In Shape / Fade Out Shape: Linear, Fast, Slow, S-Curve, Equal Power. The clip draws the curve. |
| Crossfade | Overlapping clips simply mix (that's layering). Select overlapping clips > right-click > Crossfade Overlaps: equal-power fades across each overlap. |
| Groups | Ctrl+G draws a group frame around the selection; Ctrl+Shift+G removes it (see "Groups" below). |
| Several clips at once | With several clips selected, Gain, Pitch and Pan on the Clip card change every selected clip by the same amount. |
| Mute | M mutes / unmutes the selected clips (also right-click > Mute). Muted clips are left out of the export. |
| Import here | Right-click empty grid space > Import Sound... (since 0.19.5 a double-click no longer opens it). |

**Rows** have no headers since 0.19.5: no names, colours, Mute, Solo or Lock. Mute clips with M and use a group's
M / S to mute or solo several at once (both apply to the export; the Export dock warns while a group is soloed).
Row settings saved by 0.14 to 0.19.4 stay in the file but no longer apply.

## Importing sounds (0.13)

- **File > Import Sound...** or right-click the clip grid > **Import Sound...** opens a browser for anywhere on disk:
  places (Project, Home, Desktop, Documents, Downloads, Music, drives) and favorites (☆ by the path), a search box,
  length and format for each WAV, and a waveform of the selection. Click the waveform to play from there; Space
  plays and stops; **Play on select** auditions as you step through with the arrow keys. Ctrl/Shift select several;
  Import (or Enter, or a double-click) adds them one row each at the playhead (or where you right-clicked).
- **Copy into project** (on by default, remembered): sounds from outside the project are copied to
  `res://audio_workstation_imports/<sound name>/` (the sound's file name, or its title while unsaved). An identical
  file already there is reused; a different one with the same name gets `_2`. Off: the clip uses the file where it
  is and shows "↗ outside project"; right-click > **Copy Into Project** brings it in later (undoable).
- Files dragged from Windows Explorer onto the clip grid, or from the FileSystem dock, are imported the same way.

## Saving and opening (milestone 6, engine 0.8.2)

One sound is open at a time. **File > Save / Save As** writes a Godot resource (`.tres`, or `.res`); the sound's name
and a star for unsaved changes show at the right of the toolbar. **Ctrl+S** works anywhere in the editor, double-clicking
a saved sound in the FileSystem dock opens it in the Audio tab, and New / Open / closing the editor ask first when there
are unsaved changes.
- **Safe saves:** the file is written as a temporary copy and swapped in, so a failed save never damages the old file.
- **Recovery:** a few seconds after any change, a copy goes to the editor's user data. After a crash or forced quit the
  next start offers to restore it; saving, New or Open clears it.
- **Damaged or old files:** opening checks everything (bad numbers, missing master chain, orphan curves, unknown effects)
  and repairs what it can, saying how many things were fixed. A file from a newer version is refused with a message,
  and files from older versions go through migration steps.
- **Missing sound files:** clips whose file can't be found are marked in red and stay silent, but the sound still opens.
  Clips remember the file's Godot UID, so renaming or moving it in the editor is followed, and a clip named after
  its file takes the new name. Right-click a missing clip for
  **Relink Sound File...** or **Relink From Folder...** (searches a folder by file name; undoable).
- **Editing while playing:** changing values (knobs, curve keys) keeps each effect's memory and tail, so it
  doesn't click; only adding, removing or reordering effects or clips restarts the chains. Needs engine 0.8.2 (API 9).
- **CPU meter:** the toolbar shows how much of the audio thread's time playback uses while playing; amber from 60%,
  red from 90% (dropouts). Needs engine 0.8.1 (API 8). Effect memory is now allocated on the main thread when the plan
  changes, so the audio thread no longer allocates when you edit during playback.
