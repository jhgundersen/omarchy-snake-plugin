# Snake

The build's compiling. The agent's still thinking. The good idea hasn't
shown up yet. This is what you do instead of doomscrolling: a fully
playable Snake, one click away in your Omarchy top bar.

It's a self-contained `bar-widget` plugin for [Omarchy](https://omarchy.org)'s
shell, in the same style as the built-in Audio, Network, and Bluetooth
widgets: one bar icon, one popup panel.

## Install

```sh
omarchy plugin add https://github.com/jhgundersen/omarchy-snake-plugin.git --enable
```

Or, to hack on it locally, clone it straight into your plugins directory:

```sh
git clone https://github.com/jhgundersen/omarchy-snake-plugin.git ~/.config/omarchy/plugins/jonh.snake
omarchy plugin enable jonh.snake
```

## Playing

Click the snake icon in the bar to open the panel. Each open starts a fresh
run.

- **Arrow keys or `hjkl`** — steer
- **Space** — pause/resume, or restart after a game over
- **`m`** — toggle between Levels and Endless mode
- **Esc** — close the panel
- **Click the board** — cosmetic easter egg: cycles the food through the
  apple emoji and a set of nerd-font brand glyphs (Apple, Google, Microsoft,
  GitHub, Amazon, Meta, Netflix, Spotify, Docker, Linux), tinted with the
  active omarchy theme's colors rather than each brand's own

## Levels

Two modes, swap with `m`:

- **Levels** (default) — the header shows your current level and a thin
  progress bar tracks score toward the next one. You start on **Level 1**
  with an open board; every 12 points advances a level, up to **Level 25**.
  From level 2 on, each level lays out a different wall pattern to route
  around — a bar with a gap, a cross, a ring, pillars, and a few more —
  cycling through 8 shapes across 3 difficulty tiers (the gaps get narrower
  as you go). Leveling up respawns the snake on a clear patch of the new
  layout (score and best carry over) and nudges the food to a new skin.
- **Endless** — the classic game: open board, no obstacles, no leveling,
  score just climbs.

## Files

- `manifest.json` — plugin manifest (`bar-widget` kind)
- `Panel.qml` — bar icon + popup panel + game logic, all in one entry point
