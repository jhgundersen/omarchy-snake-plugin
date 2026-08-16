import QtQuick
import qs.Ui
import qs.Commons

// Snake, playable from the bar. Bar icon opens a keyboard-driven popup with
// a small grid; arrow keys / hjkl steer, Space pauses or restarts. Each open
// starts a fresh run (onOpenedChanged below), same as summoning a game.
//
// Levels: the header shows "Level N" rather than a static title. Level is
// derived from score (one level every 5 points, capped at 25) instead of
// being stored separately, so a fresh game always starts on Level 1. From
// level 2 on, obstaclesForLevel() lays out walls to route around; collision
// only checks the *next* head cell (see tick()), so leveling up mid-run
// never retroactively kills a body segment sitting on a newly-added wall.
Panel {
  id: root
  moduleName: "jonh.snake"
  ipcTarget: "jonh.snake"

  readonly property int cols: 16
  readonly property int rows: 14
  readonly property int cellSize: 14

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
  property bool running: false
  property bool gameOver: false

  readonly property int level: Math.min(25, 1 + Math.floor(score / 5))
  readonly property var obstacles: obstaclesForLevel(level)

  // Deterministic wall layouts for levels 2-25: 8 obstacle shapes, cycling
  // through 3 difficulty tiers (gap shrinks every 8 levels). Level 1 is open.
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

  function isObstacle(x, y) {
    for (var i = 0; i < obstacles.length; i++) {
      if (obstacles[i].x === x && obstacles[i].y === y) return true
    }
    return false
  }

  // Cosmetic food skins, cycled by clicking the board: the apple emoji plus
  // ten nerd-font brand glyphs. Colors are theme tones (accent/foreground/
  // muted and light/dark variants), not brand colors, so the easter egg
  // still looks native to whatever omarchy theme is active.
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
    var glyphs = ["🍎", "󰀵", "󰊭", "󰍲", "󰊤", "", "󰈌", "󰝆", "󰓇", "󰡨", ""]
    var list = []
    for (var i = 0; i < glyphs.length; i++)
      list.push({ text: glyphs[i], color: themePalette[i % themePalette.length] })
    return list
  }
  property int foodStyleIndex: 0
  readonly property var currentFoodStyle: foodStyles[foodStyleIndex % foodStyles.length]

  function cycleFoodStyle() {
    foodStyleIndex = (foodStyleIndex + 1) % foodStyles.length
  }

  function resetGame() {
    var midY = Math.floor(rows / 2)
    snake = [
      { x: 4, y: midY },
      { x: 3, y: midY },
      { x: 2, y: midY }
    ]
    direction = { x: 1, y: 0 }
    directionQueue = []
    score = 0
    gameOver = false
    running = true
    spawnFood()
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
    if (score > best) best = score
  }

  function tick() {
    if (directionQueue.length > 0) direction = directionQueue.shift()
    var head = snake[0]
    var newHead = { x: head.x + direction.x, y: head.y + direction.y }

    if (newHead.x < 0 || newHead.x >= cols || newHead.y < 0 || newHead.y >= rows) { endGame(); return }
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

  onOpenedChanged: if (opened) resetGame()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    interval: 140
    repeat: true
    running: root.opened && root.running && !root.gameOver
    onTriggered: root.tick()
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
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.turn(dx, dy) }
      onActivateRequested: root.togglePause()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.resetGame() }

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
            text: "Level " + root.level
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
            }
          }
        }

        Text {
          width: parent.width
          text: "Arrows / hjkl to steer · Space to pause/restart"
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
