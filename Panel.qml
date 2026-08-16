import QtQuick
import qs.Ui
import qs.Commons

// Snake, playable from the bar. Bar icon opens a keyboard-driven popup with
// a small grid; arrow keys / hjkl steer, Space pauses or restarts. Each open
// starts a fresh run (onOpenedChanged below), same as summoning a game.
Panel {
  id: root
  moduleName: "jonh.snake"
  ipcTarget: "jonh.snake"

  readonly property int cols: 16
  readonly property int rows: 14
  readonly property int cellSize: 14

  property var snake: []
  property var direction: ({ x: 1, y: 0 })
  property var nextDirection: ({ x: 1, y: 0 })
  property var food: null
  property int score: 0
  property int best: 0
  property bool running: false
  property bool gameOver: false

  function resetGame() {
    var midY = Math.floor(rows / 2)
    snake = [
      { x: 4, y: midY },
      { x: 3, y: midY },
      { x: 2, y: midY }
    ]
    direction = { x: 1, y: 0 }
    nextDirection = { x: 1, y: 0 }
    score = 0
    gameOver = false
    running = true
    spawnFood()
  }

  // Picks uniformly among cells the snake doesn't occupy, rather than
  // retrying random points — keeps this correct (and terminating) even as
  // the snake fills most of a small board.
  function spawnFood() {
    var free = []
    for (var x = 0; x < cols; x++) {
      for (var y = 0; y < rows; y++) {
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
    direction = nextDirection
    var head = snake[0]
    var newHead = { x: head.x + direction.x, y: head.y + direction.y }

    if (newHead.x < 0 || newHead.x >= cols || newHead.y < 0 || newHead.y >= rows) { endGame(); return }
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

  // Ignores the reverse of the current heading so the snake can't be turned
  // directly into its own neck between ticks.
  function turn(dx, dy) {
    if (gameOver) return
    if (dx === -direction.x && dy === -direction.y) return
    nextDirection = { x: dx, y: dy }
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
    text: "🐍"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(260))
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
            text: "Snake"
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
            text: "🍎"
            font.pixelSize: root.cellSize
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
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
