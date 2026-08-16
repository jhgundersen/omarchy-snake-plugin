# Snake

A playable Snake game that lives in the Omarchy top bar — a self-contained
`bar-widget` plugin for [Omarchy](https://omarchy.org)'s shell, in the same
style as the built-in Audio, Network, and Bluetooth widgets: one bar icon,
one popup panel.

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
- **Esc** — close the panel
- **Click the board** — cosmetic easter egg: cycles the food through the
  apple emoji and a set of nerd-font brand glyphs (Apple, Google, Microsoft,
  GitHub, Amazon, Meta, Netflix, Spotify, Docker, Linux), tinted with the
  active omarchy theme's colors rather than each brand's own

## Levels

The header shows your current level instead of a static title. You start on
**Level 1** with an open board; every 5 points advances a level, up to
**Level 25**. From level 2 on, each level lays out a different wall pattern
you have to route around — a bar with a gap, a cross, a ring, pillars, and a
few more — cycling through 8 shapes across 3 difficulty tiers (the gaps get
narrower as you go).

## Files

- `manifest.json` — plugin manifest (`bar-widget` kind)
- `Panel.qml` — bar icon + popup panel + game logic, all in one entry point
