import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Snake, for the moments between: the build's compiling, the agent's still
// thinking, the idea hasn't shown up yet. Lives in the bar so it's always
// one click from wherever you already are. Arrow keys / hjkl / wasd steer,
// Space pauses or restarts, m swaps Levels/Endless, b swaps solid/wrapping
// walls. Each open starts a fresh run (onOpenedChanged below).
//
// wasd rides PanelKeyCatcher's onTextKey rather than onMoveRequested (which
// only covers arrows and hjkl), calling turn() directly with the same
// dx/dy convention.
//
// Levels mode: the header shows "Level N" and a thin progress bar tracks
// score toward the next one. Level is derived from score via
// levelForScore() instead of being stored separately, so a fresh game
// always starts on Level 1. From level 2 on,
// obstaclesForLevel() lays out walls to route around. Leveling up respawns
// the snake (score/best carry over) via findSpawnRow(), which hunts for a
// clear run of cells so the respawn never drops it straight onto a wall;
// obstacle collision only checks the *next* head cell (see tick()), so a
// body segment left sitting under a newly-added wall by that respawn
// doesn't retroactively kill it. Endless mode is the classic game: no
// obstacles, no leveling, score just climbs.
//
// wallsWrap independently swaps the board edges between solid (default,
// hitting one ends the run) and wrapping (stepping off one side re-enters
// from the opposite side, snake-cube style) in both Levels and Endless.
//
// `bestLevels`/`bestEndless` (tracked separately - `best` below just reads
// whichever one the current mode uses, they aren't comparable scores),
// `totalSeconds` (lifetime playtime, ticking alongside elapsedSeconds -
// see the 1s Timer), `foodStyleIndex` (last food skin picked - see
// cycleFoodStyle()), and `wallsWrap` persist across shell restarts as JSON
// under this plugin's own state directory (see stateDir/statePath below).
// Loaded once at startup and rewritten on every death, panel close, and
// settings change; every write merges against the last known on-disk
// values (see diskState) so a save can never regress a number another
// writer already persisted.
Panel {
  id: root
  moduleName: "jhgundersen.snake"
  ipcTarget: "jhgundersen.snake"

  readonly property int cols: 22
  readonly property int rows: 16
  readonly property int cellSize: 15

  property var snake: []
  property var direction: ({ x: 1, y: 0 })
  // Up to two turns queued ahead of the current heading. A single pending
  // slot drops the first of two quick key presses (e.g. down-then-right for
  // a corner) since the second overwrites it before the next tick reads it;
  // queueing both lets each one land on its own tick instead.
  property var directionQueue: []
  property var food: null
  property int score: 0
  // Separate records per mode - a Levels run and an Endless run aren't
  // comparable (obstacles vs. none), so beating your Endless best
  // shouldn't require out-scoring your Levels best or vice versa.
  property int bestLevels: 0
  property int bestEndless: 0
  readonly property int best: root.endlessMode ? bestEndless : bestLevels
  property bool stateLoaded: false
  property bool running: false
  property bool gameOver: false
  property bool endlessMode: false
  property bool wallsWrap: false
  property bool levelTransition: false
  property int completedLevel: 0
  property int levelSeconds: 0
  property int displayedLevel: 1

  readonly property int pointsPerLevel: 12
  readonly property int layoutsPerCycle: 8

  // The eight obstacle layouts repeat forever. Each new cycle adds one food
  // to every level's target and speeds the snake up by 7ms, down to a
  // playable 55ms floor.
  function levelCycle(lvl) {
    return lvl <= 1 ? 0 : Math.floor((lvl - 2) / layoutsPerCycle)
  }

  function pointsForLevel(lvl) {
    return pointsPerLevel + levelCycle(lvl)
  }

  function scoreForLevel(lvl) {
    var total = 0
    for (var current = 1; current < lvl; current++) total += pointsForLevel(current)
    return total
  }

  function levelForScore(s) {
    var lvl = 1
    var remaining = s
    while (remaining >= pointsForLevel(lvl)) {
      remaining -= pointsForLevel(lvl)
      lvl += 1
    }
    return lvl
  }

  readonly property int level: root.endlessMode ? 1 : levelForScore(score)
  readonly property var obstacles: root.endlessMode ? [] : obstaclesForLevel(displayedLevel)
  readonly property int tickInterval: root.endlessMode ? 140 : Math.max(55, 140 - levelCycle(level) * 7)
  readonly property real levelProgress: {
    if (root.endlessMode) return 1.0
    var base = scoreForLevel(level)
    return Math.max(0, Math.min(1, (score - base) / pointsForLevel(level)))
  }

  function toggleMode() {
    running = false
    endlessMode = !endlessMode
    resetGame()
  }

  function toggleWallsWrap() {
    wallsWrap = !wallsWrap
    saveState()
  }

  // Endless has no next level to show progress toward, so it gets a running
  // clock in the same header slot instead — keeps something worth watching
  // there and, since it occupies the same fixed-height row as the levels
  // progress bar, keeps the panel from resizing when 'm' swaps modes.
  property int elapsedSeconds: 0
  // Lifetime seconds spent playing, across every run this plugin has ever
  // seen (see the 1s Timer below), persisted the same way as `best` -
  // loaded once at startup, saved on death and on panel close.
  property int totalSeconds: 0
  readonly property string elapsedTimeText: {
    var m = Math.floor(elapsedSeconds / 60)
    var s = elapsedSeconds % 60
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
  }

  // "2m5s", "45s", "3h12m" - compact duration for the game-over quips
  // below. Drops seconds once it's long enough to need hours; nobody needs
  // lifetime playtime down to the second.
  function formatDuration(totalSeconds) {
    var h = Math.floor(totalSeconds / 3600)
    var m = Math.floor((totalSeconds % 3600) / 60)
    var s = totalSeconds % 60
    if (h > 0) return h + "h" + m + "m"
    if (m > 0) return m + "m" + s + "s"
    return s + "s"
  }

  // Rolled once when a level is cleared. Every line includes the completed
  // level and its active playtime, so the overlay always delivers the useful
  // news before immediately undermining it.
  readonly property var levelCompleteQuips: [
    "Level {level} cleared in {time}. Productivity remains at zero.",
    "You won level {level} in {time}. The build is still compiling.",
    "Level {level}: defeated in {time}. Please update your résumé.",
    "A blistering {time} for level {level}. Nobody had a stopwatch out.",
    "Level {level} took {time}. MacGyver would've used fewer apples.",
    "Level {level} cleared in {time}. The snake requests a raise.",
    "You escaped level {level} in {time}. Your inbox did not escape you.",
    "Level {level}, done in {time}. History declines to comment.",
    "Level {level} surrendered after {time}. A brave tactical retreat.",
    "Level {level} won in {time}. Confetti remains out of scope.",
    "Only {time} for level {level}. The Nokia 3310 nods respectfully.",
    "Level {level} cleared in {time}. Captain's Log: somehow adequate.",
    "You beamed through level {level} in {time}. Transporter buffer intact.",
    "Level {level} lasted {time}. Its family has been notified.",
    "Level {level}: {time}. Fast enough to avoid meaningful reflection.",
    "You conquered level {level} in {time}. The wall union is furious.",
    "Level {level} cleared in {time}. Please hold your applause indefinitely.",
    "A clean {time} on level {level}. Clean-ish. We didn't record it.",
    "Level {level} fell in {time}. Donkey Kong threw one pity barrel.",
    "You won level {level} in {time}. Your real work remains undefeated.",
    "Level {level}: completed in {time}. Achievement value: negligible.",
    "Resistance was futile for level {level}. It lasted {time}.",
    "Level {level} cleared in {time}. The agent may have finished without you.",
    "A heroic {time} victory over level {level}. Heroism sold separately.",
    "Level {level} took {time}. The Prime Directive remains technically unbroken.",
    "Level {level} cleared in {time}. Your manager sensed a disturbance.",
    "You won level {level} in {time}. Stand by for no rewards whatsoever.",
    "Level {level}: gone in {time}. It had so much left to give.",
    "A deeply average {time} victory over level {level}. Inspirational.",
    "Level {level} cleared in {time}. The shareholders remain cautiously indifferent.",
    "You finished level {level} in {time}. This meeting could have been an email.",
    "Level {level} survived for {time}. Thoughts and prayers.",
    "Level {level}: beaten in {time}. The leaderboard is just you, by the way.",
    "You gave level {level} {time} of your best procrastination.",
    "Level {level} cleared in {time}. Please return to pretending to work.",
    "A decisive {time} win on level {level}. The decision was mostly luck.",
    "Level {level} completed in {time}. Your keyboard would like a break.",
    "You outsmarted level {level} in {time}. It is a grid of rectangles.",
    "Level {level} cleared in {time}. This will look excellent on no performance review.",
    "Level {level}: {time}. Several pixels were mildly inconvenienced.",
    "You won level {level} in {time}. A tiny parade has been cancelled.",
    "Level {level} cleared in {time}. The apples have filed a complaint.",
    "A stunning {time} on level {level}. Stunningly difficult to care about.",
    "Level {level} folded after {time}. Negotiations were brief.",
    "You completed level {level} in {time}. The cloud bill is unchanged.",
    "Level {level} cleared in {time}. Somewhere, a sprint goal quietly slips.",
    "Only {time} to beat level {level}. Imagine what you could do with a purpose.",
    "Level {level}: won in {time}. Quality assurance found no quality.",
    "You cleared level {level} in {time}. The snake calls that synergy.",
    "Level {level} took {time}. Your terminal has seen enough."
  ]
  property string levelCompleteTemplate: ""
  readonly property string levelCompleteMessage: levelCompleteTemplate === "" ? "" : levelCompleteTemplate
    .replace("{time}", formatDuration(levelSeconds))
    .replace("{level}", completedLevel)

  // One-liners for the game-over screen. {time}/{score}/{level} get
  // substituted with the run that just ended (see fillGameOverTemplate()).
  // endGame() picks one pool based on whether this run just beat `best`,
  // then a random line from it once per death - not re-rolled on every
  // re-render. Kept as three flavor pools (time/score/level) plus a
  // separate highscore-only pool, rather than one flat list, so the
  // highscore case never has to accidentally roll a line that doesn't
  // mention the score.
  readonly property var timeQuips: [
    "Well, that's {time} of your life you'll never get back.",
    "{time} well spent. Definitely not wasted. Probably.",
    "The build finished ages ago. You're still here after {time}.",
    "{time} of pure focus, undone by one wrong turn.",
    "You survived {time}. The wall did not survive your ego.",
    "{time}. Not your best run. Not your worst either.",
    "Somewhere, a rubber duck is disappointed in your {time}.",
    "{time} of your one wild and precious life, gone.",
    "The snake remembers {time} of glory. Briefly.",
    "You could've stretched in {time}. You did not.",
    "{time} elapsed. Zero regrets. Okay, one regret.",
    "That wall was there the whole time. {time} of denial.",
    "{time}. Your coworkers think you're deep in thought.",
    "Legendary run of {time}. Nobody was watching.",
    "{time} down the drain, one pixel at a time.",
    "You and the wall, {time} of tension, resolved poorly.",
    "{time}. The agent finished. You did not.",
    "Achievement unlocked: {time} of avoiding real work.",
    "{time}. Worth it? Ask again after the next run.",
    "A solid {time}. The snake deserved better.",
    "Nokia 3310s have survived falls from buildings. This run didn't survive {time}.",
    "MacGyver could disarm a bomb in {time}. You could not disarm a wall.",
    "Set phasers to 'mildly disappointed'. {time} logged, captain.",
    "In Tetris, the walls are the point. Here, {time} says you disagree.",
    "Resistance to that wall was not, in fact, futile. It won in {time}."
  ]
  readonly property var scoreQuips: [
    "Score: {score}. Groundbreaking. Truly.",
    "{score} points. The bar was already low.",
    "You scored {score}. Somewhere, a real gamer wept.",
    "{score} points in {time}. Efficient, if nothing else.",
    "A modest {score}. The apple logo remains unimpressed.",
    "{score}. Write that down somewhere nobody will read it.",
    "Final score: {score}. Print it. Frame it. Ignore it.",
    "{score} points. The snake has seen better days.",
    "You call that {score}? The snake is embarrassed for you.",
    "{score}. Somewhere between 'meh' and 'why bother'.",
    "{score} points. Pac-Man's ghosts have higher kill counts and better manners.",
    "Beam this score directly into space: {score}. Nobody will find it.",
    "{score}. Even a Nokia 3310's tiny screen deserved better pixels than that.",
    "The Prime Directive says don't interfere. Your {score} interfered with nothing, including greatness.",
    "{score} points. Donkey Kong is throwing barrels of pity."
  ]
  readonly property var levelQuips: [
    "Made it to level {level}. The walls remain undefeated.",
    "Level {level}. A number. Nothing more.",
    "Level {level}, reached and then immediately un-reached.",
    "You died on level {level}, same as everyone else who tried.",
    "Level {level}. Somewhere, a wall is proud of itself.",
    "Level {level}. MacGyver would've built a ladder over that wall by now.",
    "Level {level} achieved, Captain's Log: unremarkable.",
    "Level {level}. Somewhere, a Game Boy cartridge sighs in solidarity.",
    "You beamed down to level {level} and did not beam back up.",
    "Level {level}. The Nokia snake never had it this rough."
  ]
  // {totalTime} is lifetime playtime across every run, not just this one -
  // see totalSeconds above.
  readonly property var totalTimeQuips: [
    "You've now spent {totalTime} of your life on this. No regrets. Okay, some regrets.",
    "Lifetime total: {totalTime}. Somewhere, a to-do list grows longer.",
    "{totalTime} total, across every run. The snake thanks you. The snake does not care.",
    "Grand total: {totalTime}. A monument to procrastination.",
    "{totalTime} spent here in total. Worth it? Survey says: unclear.",
    "You've fed this snake {totalTime} of your one life. It remains ungrateful.",
    "Cumulative time wasted: {totalTime}. Framed and hung with pride.",
    "{totalTime} lifetime playtime. The agent finished hours ago.",
    "All told, {totalTime}. History will not remember this.",
    "{totalTime} across every attempt. Somewhere, that's a whole movie you didn't watch.",
    "{totalTime} total. Enough time to rewatch a season of Star Trek. You chose this instead.",
    "MacGyver could've escaped a locked room in less than {totalTime}.",
    "{totalTime} lifetime, across every attempt. Nokia's battery would've outlasted you.",
    "In {totalTime} you could've beaten several retro games. You beat none of them, including this one.",
    "{totalTime}. The Enterprise could've crossed a sector in that time. You crossed a wall."
  ]
  readonly property var allGameOverQuips: timeQuips.concat(scoreQuips, levelQuips, totalTimeQuips)

  // Only rolled when this run's score beats (not ties) the previous best.
  readonly property var highscoreQuips: [
    "New high score: {score}. Somebody alert the media. Or don't.",
    "{score}! A new record. Treat yourself to absolutely nothing.",
    "Personal best: {score}. History has been made. Barely.",
    "You beat your high score with {score}. Confetti not included.",
    "{score} points, a new high score, zero prize money.",
    "New record! {score} points of undeniable, if minor, achievement.",
    "High score! {score}. The trophy is imaginary but the pride is real.",
    "You out-snaked your past self. {score}. Legendary. Ish.",
    "{score} - a new best. Somewhere, past-you is furious.",
    "Record broken: {score}. The snake salutes you. Sort of.",
    "New high score: {score}. MacGyver salutes your resourcefulness. Barely.",
    "{score}! Somewhere, a Nokia 3310 nods in grudging respect.",
    "Personal best: {score}. Log it in the ship's records. Nobody reads those either.",
    "Beam it up: {score} points, a new record, still no trophy.",
    "{score}. Insert coin for another round of mild validation."
  ]

  property string gameOverTemplate: ""
  readonly property string gameOverMessage: gameOverTemplate === "" ? "" : fillGameOverTemplate(gameOverTemplate)

  function fillGameOverTemplate(template) {
    return template
      .replace("{time}", formatDuration(elapsedSeconds))
      .replace("{totalTime}", formatDuration(totalSeconds))
      .replace("{score}", score)
      .replace("{level}", level)
  }

  // Deterministic wall layouts from level 2 onward: 8 obstacle shapes cycle
  // forever. The gap shrinks for the first 3 cycles, then holds at its
  // 2-cell floor so later levels remain possible. Level 1 is open.
  function obstaclesForLevel(lvl) {
    if (lvl <= 1) return []
    var cx = Math.floor(cols / 2)
    var cy = Math.floor(rows / 2)
    var tier = levelCycle(lvl)
    var gap = Math.max(2, 4 - tier)
    var kind = (lvl - 2) % layoutsPerCycle
    var cells = []

    function hbar(y, gapX, x0, x1) {
      for (var x = x0; x <= x1; x++) {
        if (x >= gapX && x < gapX + gap) continue
        cells.push({ x: x, y: y })
      }
    }
    function vbar(x, gapY, y0, y1) {
      for (var y = y0; y <= y1; y++) {
        if (y >= gapY && y < gapY + gap) continue
        cells.push({ x: x, y: y })
      }
    }

    if (kind === 0) { // single horizontal bar, gap in the middle
      hbar(cy, cx - Math.floor(gap / 2), 2, cols - 3)
    } else if (kind === 1) { // single vertical bar, gap in the middle
      vbar(cx, cy - Math.floor(gap / 2), 2, rows - 3)
    } else if (kind === 2) { // two horizontal bars, gaps on opposite ends
      hbar(Math.floor(rows / 3), 2, 2, cols - 3)
      hbar(Math.floor(rows * 2 / 3), cols - 2 - gap, 2, cols - 3)
    } else if (kind === 3) { // cross, gap in each arm
      hbar(cy, cx - Math.floor(gap / 2), 2, cols - 3)
      vbar(cx, cy - Math.floor(gap / 2), 2, rows - 3)
    } else if (kind === 4) { // ring with one opening
      var y0 = 2, y1 = rows - 3, x0 = 3, x1 = cols - 4
      for (var x = x0; x <= x1; x++) { cells.push({ x: x, y: y0 }); cells.push({ x: x, y: y1 }) }
      for (var y = y0 + 1; y < y1; y++) {
        cells.push({ x: x0, y: y })
        if (y < y1 - gap) cells.push({ x: x1, y: y })
      }
    } else if (kind === 5) { // diagonal staircases from opposite corners
      for (var i = 0; i < 6; i++) cells.push({ x: 3 + i, y: 3 + i })
      for (var j = 0; j < 6; j++) cells.push({ x: cols - 4 - j, y: rows - 4 - j })
    } else if (kind === 6) { // scattered pillars
      for (var px = 3; px <= cols - 4; px += 3)
        for (var py = 2; py <= rows - 3; py += 3)
          if ((px + py) % 2 === 0) cells.push({ x: px, y: py })
    } else { // offset zigzag bars
      hbar(4, 2, 2, 8)
      hbar(rows - 5, cols - 9, 7, cols - 3)
    }
    return cells
  }

  // Deliberately calls obstaclesForLevel() directly instead of reading the
  // `obstacles` property. `obstacles` is a binding derived from `level`,
  // and QML can leave a multi-hop binding like that stale for a moment
  // after the more direct property (`level`) has already updated and
  // fired its changed signal — confirmed by tracing an actual level-up:
  // onLevelChanged saw level 2 but obstacles.length was still 0 (level
  // 1's, empty). respawnSnake() then treated the board as wide open and
  // placed the snake right where the real level-2 wall was about to
  // render. A plain function call has no cache to go stale.
  function isObstacle(x, y) {
    var list = root.endlessMode ? [] : obstaclesForLevel(level)
    for (var i = 0; i < list.length; i++) {
      if (list[i].x === x && list[i].y === y) return true
    }
    return false
  }

  // Cosmetic food skins, cycled with 'f' or by clicking the board: a
  // handful of fruit emoji plus a few nerd-font brand glyphs. Brand-glyph
  // colors are theme tones (accent/foreground/muted and light/dark
  // variants), not brand colors, so the easter egg still looks native to
  // whatever omarchy theme is active.
  readonly property color themeForeground: bar ? bar.foreground : Color.foreground
  readonly property var themePalette: [
    themeForeground,
    Color.accent,
    Color.muted,
    Qt.lighter(Color.accent, 1.35),
    Qt.darker(Color.accent, 1.35),
    Qt.lighter(themeForeground, 1.3),
    Qt.lighter(Color.muted, 1.25),
    Qt.darker(themeForeground, 1.3)
  ]
  readonly property var foodStyles: {
    var glyphs = ["🍎", "🍇", "🍓", "🍒", "🍉", "󰀵", "󰊤", "󰡨", ""]
    var list = []
    for (var i = 0; i < glyphs.length; i++)
      list.push({ text: glyphs[i], color: themePalette[i % themePalette.length] })
    return list
  }
  property int foodStyleIndex: 0
  readonly property var currentFoodStyle: foodStyles[foodStyleIndex % foodStyles.length]

  function cycleFoodStyle() {
    foodStyleIndex = (foodStyleIndex + 1) % foodStyles.length
    saveState()
  }

  // Scans for a run of `runLen` clear cells in a row, starting from the
  // vertical middle and fanning outward — so a level's obstacles (which are
  // usually centered) never force the snake to spawn on a wall.
  function findClearRun(runLen) {
    var preferredY = Math.floor(rows / 2)
    for (var offset = 0; offset < rows; offset++) {
      var y = preferredY + (offset % 2 === 0 ? offset / 2 : -(offset + 1) / 2)
      if (y < 0 || y >= rows) continue
      for (var x = 2; x <= cols - runLen - 1; x++) {
        var clear = true
        for (var k = 0; k < runLen; k++) {
          if (isObstacle(x + k, y)) { clear = false; break }
        }
        if (clear) return { x: x, y: y }
      }
    }
    return null
  }

  // 3 cells for the body plus enough runway ahead that heading straight
  // right for a couple of ticks can't walk it straight into a wall it just
  // spawned next to. Tries a generous runway first and only settles for a
  // shorter one if the level's obstacles don't leave anything longer.
  function findSpawnRow() {
    for (var runLen = 10; runLen >= 4; runLen -= 2) {
      var spot = findClearRun(runLen)
      if (spot) return spot
    }
    return { x: 2, y: Math.floor(rows / 2) }
  }

  function respawnSnake() {
    var spot = findSpawnRow()
    snake = [
      { x: spot.x + 2, y: spot.y },
      { x: spot.x + 1, y: spot.y },
      { x: spot.x, y: spot.y }
    ]
    direction = { x: 1, y: 0 }
    directionQueue = []
    spawnFood()
  }

  function resetGame() {
    running = false
    levelTransitionTimer.stop()
    levelBoardTransition.stop()
    boardContent.opacity = 1
    score = 0
    displayedLevel = level
    elapsedSeconds = 0
    levelSeconds = 0
    levelTransition = false
    completedLevel = 0
    levelCompleteTemplate = ""
    gameOver = false
    gameOverTemplate = ""
    running = true
    respawnSnake()
  }

  // Keep the completed layout on screen long enough to fade it out, then
  // swap and respawn while the board content is invisible. Guarded by
  // `running` so resetGame()'s score reset doesn't start a transition.
  onLevelChanged: {
    if (!running || endlessMode) return
    completedLevel = level - 1
    levelCompleteTemplate = levelCompleteQuips[Math.floor(Math.random() * levelCompleteQuips.length)]
    levelTransition = true
    levelBoardTransition.restart()
    levelTransitionTimer.restart()
  }

  // Picks uniformly among cells the snake and the current level's obstacles
  // don't occupy, rather than retrying random points — keeps this correct
  // (and terminating) even as the board fills up.
  function spawnFood() {
    var free = []
    for (var x = 0; x < cols; x++) {
      for (var y = 0; y < rows; y++) {
        if (isObstacle(x, y)) continue
        var occupied = false
        for (var i = 0; i < snake.length; i++) {
          if (snake[i].x === x && snake[i].y === y) { occupied = true; break }
        }
        if (!occupied) free.push({ x: x, y: y })
      }
    }
    if (free.length === 0) { endGame(); return }
    food = free[Math.floor(Math.random() * free.length)]
  }

  function endGame() {
    gameOver = true
    running = false
    var isNewBest = score > best
    if (isNewBest) {
      if (endlessMode) bestEndless = score
      else bestLevels = score
    }
    saveState()
    var pool = isNewBest ? highscoreQuips : allGameOverQuips
    gameOverTemplate = pool[Math.floor(Math.random() * pool.length)]
  }

  function tick() {
    if (directionQueue.length > 0) direction = directionQueue.shift()
    var head = snake[0]
    var newHead = { x: head.x + direction.x, y: head.y + direction.y }

    if (newHead.x < 0 || newHead.x >= cols || newHead.y < 0 || newHead.y >= rows) {
      if (!wallsWrap) { endGame(); return }
      newHead.x = (newHead.x + cols) % cols
      newHead.y = (newHead.y + rows) % rows
    }
    if (isObstacle(newHead.x, newHead.y)) { endGame(); return }
    for (var i = 0; i < snake.length; i++) {
      if (snake[i].x === newHead.x && snake[i].y === newHead.y) { endGame(); return }
    }

    var ateFood = !!food && newHead.x === food.x && newHead.y === food.y
    var newSnake = [newHead].concat(snake)
    if (!ateFood) newSnake.pop()
    snake = newSnake

    if (ateFood) {
      score += 1
      if (!levelTransition) spawnFood()
    }
  }

  // Queues a turn against the last queued heading (or the current one if
  // nothing is queued yet), so it rejects reversing into the snake's own
  // neck without discarding a second legitimate turn queued right after it.
  function turn(dx, dy) {
    if (gameOver || levelTransition) return
    var last = directionQueue.length > 0 ? directionQueue[directionQueue.length - 1] : direction
    if (dx === -last.x && dy === -last.y) return
    if (dx === last.x && dy === last.y) return
    if (directionQueue.length >= 2) return
    directionQueue.push({ x: dx, y: dy })
  }

  function togglePause() {
    if (levelTransition) return
    if (gameOver) { resetGame(); return }
    running = !running
  }

  // Best score and lifetime playtime survive shell restarts via a small
  // JSON file under this plugin's own state directory -
  // $XDG_STATE_HOME/omarchy/plugins/<id>/, mirroring where first-party
  // plugins (e.g. notifications, weather) keep their own persisted state
  // under ~/.local/state/omarchy/. Namespaced by moduleName rather than
  // dropped straight in that shared directory so a third-party plugin's
  // file can't collide with anyone else's.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/plugins/" + root.moduleName + "/"
  readonly property string statePath: stateDir + "state.json"

  // Last snapshot known to be on disk (null until the first load
  // resolves). saveState() merges against this - not just against live
  // in-memory values - so a stale/lower value here can never overwrite a
  // higher one another writer (a sibling instance on another monitor, or
  // just an earlier save this same instance already made) put there.
  // watchChanges + onFileChanged keep it current if anything else
  // touches the file while this instance is alive.
  property var diskState: null

  function extractState(parsed) {
    var d = parsed || {}
    return {
      bestLevels: typeof d.bestLevels === "number" ? d.bestLevels : (typeof d.best === "number" ? d.best : 0),
      bestEndless: typeof d.bestEndless === "number" ? d.bestEndless : 0,
      totalSeconds: typeof d.totalSeconds === "number" ? d.totalSeconds : 0,
      foodStyleIndex: typeof d.foodStyleIndex === "number" ? Math.floor(d.foodStyleIndex) : -1,
      wallsWrap: typeof d.wallsWrap === "boolean" ? d.wallsWrap : false
    }
  }

  function recordDiskState(raw) {
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    diskState = extractState(parsed)
    // onLoaded can fire more than once during startup (the implicit
    // preload plus the explicit reload() below); only the first one
    // should seed live play state, or a later reload could stomp
    // progress made by actual play in between.
    if (stateLoaded) return
    if (diskState.bestLevels > bestLevels) bestLevels = diskState.bestLevels
    if (diskState.bestEndless > bestEndless) bestEndless = diskState.bestEndless
    if (diskState.totalSeconds > totalSeconds) totalSeconds = diskState.totalSeconds
    if (diskState.foodStyleIndex >= 0 && diskState.foodStyleIndex < foodStyles.length)
      foodStyleIndex = diskState.foodStyleIndex
    wallsWrap = diskState.wallsWrap
    stateLoaded = true
  }

  // Called on every death and whenever the panel closes (see
  // onOpenedChanged) or the food skin changes, not just on a new best,
  // since totalSeconds and foodStyleIndex move independently of the score.
  function saveState() {
    if (!stateLoaded) return
    var d = diskState || extractState(null)
    bestLevels = Math.max(bestLevels, d.bestLevels)
    bestEndless = Math.max(bestEndless, d.bestEndless)
    totalSeconds = Math.max(totalSeconds, d.totalSeconds)
    var payload = {
      version: 3,
      bestLevels: root.bestLevels,
      bestEndless: root.bestEndless,
      totalSeconds: root.totalSeconds,
      foodStyleIndex: root.foodStyleIndex,
      wallsWrap: root.wallsWrap
    }
    diskState = extractState(payload)
    stateFile.setText(JSON.stringify(payload, null, 2) + "\n")
  }

  Process {
    id: ensureStateDirProc
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.recordDiskState(text())
    // First run: the file doesn't exist yet. Without this, stateLoaded
    // stays false forever and saveState() becomes a permanent no-op.
    onLoadFailed: root.recordDiskState("")
  }

  Component.onCompleted: {
    ensureStateDirProc.running = true
    Qt.callLater(function() { stateFile.reload() })
  }

  onOpenedChanged: {
    if (opened) resetGame()
    else saveState()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    interval: root.tickInterval
    repeat: true
    running: root.opened && root.running && !root.gameOver && !root.levelTransition
    onTriggered: root.tick()
  }

  SequentialAnimation {
    id: levelBoardTransition

    NumberAnimation {
      target: boardContent
      property: "opacity"
      from: 1
      to: 0
      duration: 400
      easing.type: Easing.InOutCubic
    }
    ScriptAction {
      script: {
        root.displayedLevel = root.level
        root.respawnSnake()
      }
    }
    NumberAnimation {
      target: boardContent
      property: "opacity"
      from: 0
      to: 1
      duration: 500
      easing.type: Easing.OutCubic
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.running && !root.gameOver && !root.levelTransition
    onTriggered: {
      root.elapsedSeconds += 1
      root.totalSeconds += 1
      if (!root.endlessMode) root.levelSeconds += 1
    }
  }

  Timer {
    id: levelTransitionTimer
    interval: 2400
    onTriggered: {
      root.levelTransition = false
      root.levelSeconds = 0
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱔎"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.turn(dx, dy) }
      onActivateRequested: root.togglePause()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.resetGame()
        else if (t === "m" || t === "M") root.toggleMode()
        else if (t === "f" || t === "F") root.cycleFoodStyle()
        else if (t === "b" || t === "B") root.toggleWallsWrap()
        else if (t === "w" || t === "W") root.turn(0, -1)
        else if (t === "a" || t === "A") root.turn(-1, 0)
        else if (t === "s" || t === "S") root.turn(0, 1)
        else if (t === "d" || t === "D") root.turn(1, 0)
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(10)

        Item {
          width: parent.width
          implicitHeight: title.implicitHeight

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.endlessMode ? "Endless" : ("Level " + root.level)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Score " + root.score + (root.best > 0 ? "  ·  Best " + root.best : "")
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        // Fixed-height regardless of mode so toggling 'm' never resizes the
        // panel: Levels shows progress toward the next level; Endless has
        // no next level to track, so it gets a running clock instead.
        Item {
          width: parent.width
          height: Style.space(18)

          Rectangle {
            width: parent.width
            height: Style.space(5)
            radius: height / 2
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.endlessMode
            color: Qt.darker(root.bar.foreground, 3.5)

            Rectangle {
              width: parent.width * root.levelProgress
              height: parent.height
              radius: height / 2
              color: Color.accent

              Behavior on width {
                NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.endlessMode
            text: root.elapsedTimeText
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Rectangle {
          id: board
          width: root.cols * root.cellSize
          height: root.rows * root.cellSize
          anchors.horizontalCenter: parent.horizontalCenter
          color: Color.background
          border.color: Qt.darker(root.bar.foreground, 2.2)
          border.width: 1
          radius: 4
          clip: true

          Item {
            id: boardContent
            anchors.fill: parent

            Repeater {
              model: root.obstacles
              Rectangle {
                required property var modelData
                x: modelData.x * root.cellSize + 1
                y: modelData.y * root.cellSize + 1
                width: root.cellSize - 2
                height: root.cellSize - 2
                radius: 1
                color: Color.muted
                opacity: 0.8
              }
            }

            Repeater {
              model: root.snake
              Rectangle {
                required property var modelData
                required property int index
                x: modelData.x * root.cellSize + 1
                y: modelData.y * root.cellSize + 1
                width: root.cellSize - 2
                height: root.cellSize - 2
                radius: 3
                color: index === 0 ? root.bar.foreground : Color.accent
              }
            }

            Text {
              visible: !!root.food
              x: root.food ? root.food.x * root.cellSize : 0
              y: root.food ? root.food.y * root.cellSize : 0
              width: root.cellSize
              height: root.cellSize
              text: root.currentFoodStyle.text
              color: root.currentFoodStyle.color
              font.family: root.bar.fontFamily
              font.pixelSize: root.cellSize
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
          }

          // Easter egg: click the board to skin the food as a different
          // brand glyph. Purely cosmetic — collision still keys off
          // food.x/food.y, not which glyph is showing.
          MouseArea {
            anchors.fill: parent
            onClicked: root.cycleFoodStyle()
          }

          Rectangle {
            anchors.fill: parent
            visible: root.gameOver || !root.running || root.levelTransition
            color: Qt.rgba(0, 0, 0, 0.55)

            Column {
              anchors.centerIn: parent
              spacing: Style.space(4)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.levelTransition ? ("LEVEL " + root.completedLevel + " CLEARED") : (root.gameOver ? "GAME OVER" : "PAUSED")
                color: "#ffffff"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.levelTransition ? ("Level " + root.level + " incoming") : (root.gameOver ? "Space to restart" : "Space to resume")
                color: "#ffffff"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: root.gameOver || root.levelTransition
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.levelTransition ? root.levelCompleteMessage : root.gameOverMessage
                color: "#ffffff"
                opacity: 0.7
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                // The enclosing Column has no explicit width of its own (it
                // sizes to its widest child), so binding to board.width
                // here instead of parent.width avoids a circular sizing
                // dependency that would squeeze this down to near nothing.
                width: board.width - Style.space(24)
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "Steer with arrows, hjkl, or wasd · Space to pause"
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        // Each of these doubles as a mouse target for the same toggle its
        // key does, so the current value (mode/food skin/border behavior)
        // is both visible and clickable without opening a menu.
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(14)

          HintLabel {
            text: "mode(m): " + (root.endlessMode ? "Endless" : "Levels")
            onClicked: root.toggleMode()
          }
          HintLabel {
            text: "borders(b): " + (root.wallsWrap ? "Wrap" : "Solid")
            onClicked: root.toggleWallsWrap()
          }
          HintLabel {
            text: "food(f): " + root.currentFoodStyle.text
            onClicked: root.cycleFoodStyle()
          }
        }
      }
    }
  }

  // Clickable status label for the bottom hint row: mode/food/borders each
  // show their current value and share this so a click acts the same as
  // the key it names. Brightens to full foreground on hover.
  component HintLabel: Item {
    id: hintLabel
    required property string text
    signal clicked()

    implicitWidth: label.implicitWidth
    implicitHeight: label.implicitHeight

    Text {
      id: label
      text: hintLabel.text
      color: mouseArea.containsMouse ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption

      Behavior on color { ColorAnimation { duration: 100 } }
    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: hintLabel.clicked()
    }
  }
}
