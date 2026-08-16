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
// levelThresholds (see levelForScore()) instead of being stored
// separately, so a fresh game always starts on Level 1. From level 2 on,
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
// `best`, `totalSeconds` (lifetime playtime, ticking alongside
// elapsedSeconds - see the 1s Timer), and `foodStyleIndex` (last food skin
// picked - see cycleFoodStyle()) persist across shell restarts as JSON
// under this plugin's own state directory (see stateDir/statePath below),
// loaded once at startup and rewritten on every death, panel close, and
// food-skin change.
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
  property int best: 0
  property bool stateLoaded: false
  property bool running: false
  property bool gameOver: false
  property bool endlessMode: false
  property bool wallsWrap: false

  readonly property int pointsPerLevel: 12
  readonly property int maxLevel: 50
  // Levels 1-25 cost a flat pointsPerLevel each. Past that, every further
  // level costs one more point than the last (26 needs 13 more, 27 needs
  // 14 more, ...), so the climb past 25 gradually gets longer instead of
  // the difficulty plateauing while the pace stays flat forever.
  readonly property int flatLevelCap: 25

  // levelThresholds[i] is the score at which level (i + 1) is reached, so
  // levelThresholds[0] === 0 (level 1) through levelThresholds[maxLevel-1]
  // (level maxLevel).
  readonly property var levelThresholds: {
    var arr = [0]
    for (var lvl = 2; lvl <= maxLevel; lvl++) {
      var prevLevel = lvl - 1
      var cost = prevLevel < flatLevelCap ? pointsPerLevel : pointsPerLevel + (prevLevel - flatLevelCap + 1)
      arr.push(arr[arr.length - 1] + cost)
    }
    return arr
  }

  function levelForScore(s) {
    var arr = levelThresholds
    var lvl = 1
    for (var i = 1; i < arr.length; i++) {
      if (s < arr[i]) break
      lvl = i + 1
    }
    return lvl
  }

  readonly property int level: root.endlessMode ? 1 : levelForScore(score)
  readonly property var obstacles: root.endlessMode ? [] : obstaclesForLevel(level)
  readonly property real levelProgress: {
    if (root.endlessMode || level >= maxLevel) return 1.0
    var base = levelThresholds[level - 1]
    var next = levelThresholds[level]
    return Math.max(0, Math.min(1, (score - base) / (next - base)))
  }

  function toggleMode() {
    endlessMode = !endlessMode
    resetGame()
  }

  function toggleWallsWrap() {
    wallsWrap = !wallsWrap
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
    "A solid {time}. The snake deserved better."
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
    "{score}. Somewhere between 'meh' and 'why bother'."
  ]
  readonly property var levelQuips: [
    "Made it to level {level}. The walls remain undefeated.",
    "Level {level}. A number. Nothing more.",
    "Level {level}, reached and then immediately un-reached.",
    "You died on level {level}, same as everyone else who tried.",
    "Level {level}. Somewhere, a wall is proud of itself."
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
    "{totalTime} across every attempt. Somewhere, that's a whole movie you didn't watch."
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
    "Record broken: {score}. The snake salutes you. Sort of."
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

  // Deterministic wall layouts for levels 2-50: 8 obstacle shapes, cycling
  // every 8 levels. The gap shrinks each cycle for the first 3 (levels
  // 2-25), then holds at its 2-cell floor for the rest, so levels 26+ keep
  // rotating through the same 8 shapes at the max difficulty rather than
  // becoming impossible. Level 1 is open.
  function obstaclesForLevel(lvl) {
    if (lvl <= 1) return []
    var cx = Math.floor(cols / 2)
    var cy = Math.floor(rows / 2)
    var tier = Math.floor((lvl - 2) / 8)
    var gap = Math.max(2, 4 - tier)
    var kind = (lvl - 2) % 8
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
    score = 0
    elapsedSeconds = 0
    gameOver = false
    gameOverTemplate = ""
    running = true
    respawnSnake()
  }

  // Leveling up mid-run gives the snake a fresh, obstacle-clear start on
  // the new layout instead of leaving it to navigate straight into a wall
  // that just appeared. Guarded by `running` so this doesn't also fire from
  // resetGame()'s own score reset (that already calls respawnSnake once).
  // Food skin is left alone here - it's a player choice (see
  // cycleFoodStyle()), not something a level change should touch.
  onLevelChanged: {
    if (!running) return
    respawnSnake()
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
    if (isNewBest) best = score
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
      spawnFood()
    }
  }

  // Queues a turn against the last queued heading (or the current one if
  // nothing is queued yet), so it rejects reversing into the snake's own
  // neck without discarding a second legitimate turn queued right after it.
  function turn(dx, dy) {
    if (gameOver) return
    var last = directionQueue.length > 0 ? directionQueue[directionQueue.length - 1] : direction
    if (dx === -last.x && dy === -last.y) return
    if (dx === last.x && dy === last.y) return
    if (directionQueue.length >= 2) return
    directionQueue.push({ x: dx, y: dy })
  }

  function togglePause() {
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

  function loadState(raw) {
    // onLoaded can fire more than once during startup (the implicit preload
    // plus the explicit reload() below); only the first one should apply,
    // or a later reload of the file we just wrote could stomp progress made
    // by actual play in between.
    if (stateLoaded) return
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    if (parsed && typeof parsed.best === "number" && parsed.best > best) best = Math.floor(parsed.best)
    if (parsed && typeof parsed.totalSeconds === "number" && parsed.totalSeconds > totalSeconds)
      totalSeconds = Math.floor(parsed.totalSeconds)
    if (parsed && typeof parsed.foodStyleIndex === "number") {
      var idx = Math.floor(parsed.foodStyleIndex)
      if (idx >= 0 && idx < foodStyles.length) foodStyleIndex = idx
    }
    stateLoaded = true
  }

  // Called on every death and whenever the panel closes (see
  // onOpenedChanged), not just on a new best, since totalSeconds moves
  // independently of the score.
  function saveState() {
    if (!stateLoaded) return
    stateFile.setText(JSON.stringify({
      version: 1,
      best: root.best,
      totalSeconds: root.totalSeconds,
      foodStyleIndex: root.foodStyleIndex
    }, null, 2) + "\n")
  }

  Process {
    id: ensureStateDirProc
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    // First run: the file doesn't exist yet. Without this, stateLoaded
    // stays false forever and saveState() becomes a permanent no-op.
    onLoadFailed: root.loadState("")
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
    interval: 140
    repeat: true
    running: root.opened && root.running && !root.gameOver
    onTriggered: root.tick()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.running && !root.gameOver
    onTriggered: {
      root.elapsedSeconds += 1
      root.totalSeconds += 1
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

          // Easter egg: click the board to skin the food as a different
          // brand glyph. Purely cosmetic — collision still keys off
          // food.x/food.y, not which glyph is showing.
          MouseArea {
            anchors.fill: parent
            onClicked: root.cycleFoodStyle()
          }

          Rectangle {
            anchors.fill: parent
            visible: root.gameOver || !root.running
            color: Qt.rgba(0, 0, 0, 0.55)

            Column {
              anchors.centerIn: parent
              spacing: Style.space(4)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.gameOver ? "GAME OVER" : "PAUSED"
                color: "#ffffff"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.gameOver ? "Space to restart" : "Space to resume"
                color: "#ffffff"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: root.gameOver
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.gameOverMessage
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
