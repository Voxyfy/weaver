# Weaver design notes

How a nesting window manager behaves, written down after studying the idea in use (TrellisWM 0.9.5,
October 2026) and deciding what Weaver does the same, differently, or not at all. Observations are
ours; nothing here is copied from anyone's code.

## The model

- **The Desktop is a cell.** The root of each display is not "empty": it is the Desktop tile, which holds
  every floating window at its own position. Docking the first window to an edge splits the screen into
  `[Desktop | window]`, and the Desktop tile shrinks with everything in it, scaled proportionally. Floating
  windows therefore never disappear; they get smaller. This is the single most important behaviour and
  the one Weaver still lacks (today the first dock fills the screen and other windows stay behind).
- **Spaces nest.** A cell can hold a split, a split can hold a cell with another split, as deep as the user
  likes. Dropping a window on a cell's edge band splits that cell; dropping on a screen edge splits the
  whole display.
- **Zoom is a camera.** Zooming into a cell lays that subtree out across the display. Windows outside the
  camera are not hidden: they are squeezed below their app's minimum size and covered by a tile showing
  the app's colour and icon ("a window too small for its app shows as its icon until there's room;
  double-click it to go in"). Weaver currently just raises the focused subtree; tiles are next.
- **Tab groups.** Dropping a window on the middle of another and pausing stacks them under one tab strip
  drawn by the manager above the window. The strip is a window of the manager's own; the red, yellow and
  green buttons on it act on the whole group. Tabs can be dragged out again.
- **Saved views** are camera positions, numbered 1–9, shown in the menu bar.

## Interaction inventory (what we saw)

| Gesture | Result |
|---|---|
| Drag a window to a screen edge | Blue preview on that edge; drop docks it beside everything (the Desktop keeps the rest) |
| Drag onto another window's edge band | Preview over that half; drop splits the cell |
| Drag onto another window's middle and pause | Target gets a blue border; drop makes a tab group |
| Drag the gap between two windows | Both resize |
| Double-click a title bar | Camera frames that window; again to go back |
| Double-click the Desktop | Camera frames the Desktop |
| ⌥-pinch | Zoom the camera; let go and it settles on the best-fitting space |
| ⌃⌥Space | Everything |
| ⌃⌥↑ / ↓ | Step out / in (toward the focused window or the pointer, a setting) |
| ⌃⌥← → (⇧↑↓) | Neighbouring space |
| ⌃⌥[ ] | Back / forward through camera history |
| ⌃⌥↩ | Frame focused window on its own |
| ⌃⌥D | Hide/show the Desktop in this space |
| ⌃⌥N | Split the active tile with a new Finder window |
| Green button | Docks/floats instead of full screen (⌥-click still zooms) |
| Right-click menu bar icon | Saved Views, Show Desktop in This Space, Arrange Windows, Float All Windows on Desktop, Don't Arrange "App", Settings, Quit |

While dragging, the manager draws the moving window as a *picture* (ScreenCaptureKit) and only moves the
real window on drop; without the Screen Recording permission the picture is a colour block with the app icon.

Settings panes: General (login item, updates, permissions status, turn off macOS edge tiling / click-wallpaper
/ Stage Manager with a "Turn Back On" button), Windows (gap slider, squeeze-below-minimum, green button
behaviour, docking into the Desktop tile), Tabs (strip style, chip, close buttons, whether window buttons act on
the group), Appearance (preview darkness, picture-or-icon previews, which menu bar controls appear and in what
order), Gestures (pinch target, step-in target), Apps (never arrange these), Shortcuts (all rebindable), License.

## What Weaver does differently

- **Open source, MIT, free.** No tiers, no docked-window cap.
- **Drag previews.** An event tap takes the drag over after 12 pt: the real window stays put, a half-size
  picture (ScreenCaptureKit when Screen Recording is allowed, otherwise the app icon on a grey card) follows the
  pointer, and the drop decides. The app's own drag is ended with a tagged synthetic mouse-up.
- **Keyboard first.** Every move has a shortcut from day one; gestures follow.
- **Own look.** Our own icon, colours and tab strip. We take the behaviours, not the skin.

## Roadmap

1. **Desktop tile** – floating windows live in a cell that scales. (Replaces "first dock fills the screen".)
2. **Tiles for squeezed windows** – overlay panel with app icon, double-click to zoom in.
3. **Tab groups** – strip panel above the group, one window visible at a time, drag out to split.
4. **Camera history** – back/forward, neighbouring spaces, step in/out toward the pointer.
5. **Saved views** – numbered, in the menu bar.
6. **Settings window** – gap, shortcuts, excluded apps, launch at login.
7. **Live drag previews** – ScreenCaptureKit, optional permission.
