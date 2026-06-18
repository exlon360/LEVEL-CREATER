import AudioToolbox
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @State private var levels: [EditableLevel]
    @State private var selectedLevelIndex = 0
    @State private var level: EditableLevel
    @State private var selectedTool: CreatorTool = .block
    @State private var hotbarTools = CreatorTool.defaultHotbarTools
    @State private var undoStack: [EditableLevel] = []
    @State private var redoStack: [EditableLevel] = []
    @State private var camera = CGPoint(x: 0, y: 3)
    @State private var zoom: CGFloat = 1.0
    @State private var jumpPadPower = GameConstants.defaultJumpPadPower
    @State private var isBlockLibraryPresented = false
    @State private var isPlaying = false
    @State private var playState: LevelPlayState
    @State private var isPressingLeft = false
    @State private var isPressingRight = false
    @State private var queuedJump = false
    @State private var lastTickDate: Date?

    private let gameTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    init() {
        let savedLevels = EditableLevel.savedSet()
        let initialLevel = savedLevels.first ?? EditableLevel.starter()
        _levels = State(initialValue: savedLevels)
        _level = State(initialValue: initialLevel)
        _playState = State(initialValue: LevelPlayState(level: initialLevel))
    }

    var body: some View {
        ZStack {
            AppBackdrop()

            VStack(spacing: 10) {
                if isPlaying == false {
                    header

                    LevelControls(
                        levelIndex: selectedLevelIndex,
                        levelCount: levels.count,
                        previousAction: previousLevel,
                        nextAction: nextLevel,
                        addAction: addLevel,
                        saveAction: saveCustomLevel
                    )

                    StatusStrip(
                        isPlaying: isPlaying,
                        selectedTool: selectedTool,
                        level: level,
                        playState: playState
                    )
                }

                LevelCanvasView(
                    level: level,
                    selectedTool: selectedTool,
                    camera: camera,
                    zoom: zoom,
                    isPlaying: isPlaying,
                    playState: playState,
                    applyAction: applyTool,
                    movingDragAction: { start, end, recordsUndo in
                        updateMovingPlatform(
                            start: start,
                            end: end,
                            isLethal: selectedTool == .redMoving,
                            recordsUndo: recordsUndo
                        )
                    },
                    cameraDragAction: moveCameraByDrag(dx:dy:)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 4)

                if isPlaying {
                    PlayControls(
                        isPressingLeft: $isPressingLeft,
                        isPressingRight: $isPressingRight,
                        jumpAction: { queuedJump = true },
                        attackAction: performAttack,
                        createAction: togglePlay,
                        canAttack: playState.attackCooldown <= 0
                    )
                } else {
                    EditorControls(
                        selectedTool: $selectedTool,
                        hotbarTools: hotbarTools,
                        jumpPadPower: $jumpPadPower,
                        camera: camera,
                        zoom: zoom,
                        canUndo: undoStack.isEmpty == false,
                        canRedo: redoStack.isEmpty == false,
                        undoAction: undoEdit,
                        redoAction: redoEdit,
                        libraryAction: { isBlockLibraryPresented = true },
                        zoomInAction: zoomIn,
                        zoomOutAction: zoomOut,
                        removeAllAction: removeAll
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if isPlaying {
                PlayHeartHUD(health: playState.health)
                    .padding(.top, 14)
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            camera = clampedCamera(x: 0, y: 3)
        }
        .sheet(isPresented: $isBlockLibraryPresented) {
            BlockLibraryView(
                selectedTool: $selectedTool,
                jumpPadPower: $jumpPadPower,
                hotbarTools: $hotbarTools
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onReceive(gameTimer) { date in
            guard isPlaying else {
                lastTickDate = date
                return
            }

            let delta = min(CGFloat(date.timeIntervalSince(lastTickDate ?? date)), 1.0 / 20.0)
            lastTickDate = date
            stepPlay(deltaTime: delta)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isPlaying)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Level Creator")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(isPlaying ? playState.statusText : selectedTool.hint)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)

            Button {
                togglePlay()
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: isPlaying ? "hammer.fill" : "play.fill")
                        .font(.system(size: 22, weight: .black))
                    Text(isPlaying ? "Create" : "Play")
                        .font(.caption.weight(.black))
                }
                .frame(width: 76, height: 62)
            }
            .buttonStyle(GreenModeButtonStyle())
        }
    }

    private func applyTool(at point: LevelGridPoint) {
        guard level.contains(point) else { return }

        var didEdit = true
        recordUndoSnapshot()
        switch selectedTool {
        case .block:
            level.tiles[point] = .block
            removeActors(at: point)
        case .kill:
            level.tiles[point] = .kill
            removeActors(at: point)
        case .water:
            level.tiles[point] = .water
            removeActors(at: point)
        case .space:
            level.tiles[point] = .space
            removeActors(at: point)
        case .jumpPad:
            level.tiles[point] = .jumpPad(power: jumpPadPower)
            removeActors(at: point)
        case .ice:
            level.tiles[point] = .ice
            removeActors(at: point)
        case .mud:
            level.tiles[point] = .mud
            removeActors(at: point)
        case .conveyorLeft:
            level.tiles[point] = .conveyorLeft
            removeActors(at: point)
        case .conveyorRight:
            level.tiles[point] = .conveyorRight
            removeActors(at: point)
        case .spring:
            level.tiles[point] = .spring
            removeActors(at: point)
        case .checkpoint:
            level.tiles[point] = .checkpoint
            removeActors(at: point)
        case .heal:
            level.tiles[point] = .heal
            removeActors(at: point)
        case .coin:
            level.tiles[point] = .coin
            removeActors(at: point)
        case .key:
            level.tiles[point] = .key
            removeActors(at: point)
        case .lock:
            level.tiles[point] = .lock
            removeActors(at: point)
        case .turret:
            level.tiles[point] = .turret
            removeActors(at: point)
        case .homingTurret:
            level.tiles[point] = .homingTurret
            removeActors(at: point)
        case .moving, .redMoving:
            let end = level.clamped(LevelGridPoint(x: point.x + 4, y: point.y))
            updateMovingPlatform(start: point, end: end, isLethal: selectedTool == .redMoving, recordsUndo: false)
            return
        case .enemy:
            level.tiles[point] = nil
            level.movingPlatforms.removeAll { $0.touches(point) }
            if level.enemies.contains(point) {
                level.enemies.remove(point)
            } else if point != level.start && point != level.end {
                level.enemies.insert(point)
            }
        case .start:
            level.tiles[point] = nil
            removeActors(at: point)
            level.start = point
        case .end:
            level.tiles[point] = nil
            removeActors(at: point)
            level.end = point
        case .delete:
            level.tiles[point] = nil
            level.enemies.remove(point)
            level.movingPlatforms.removeAll { $0.touches(point) }
        case .move:
            didEdit = false
            discardUnusedUndoSnapshot()
            break
        }

        if didEdit {
            persistCurrentLevel()
            playEditorSound(for: selectedTool)
        }
    }

    private func removeActors(at point: LevelGridPoint) {
        level.enemies.remove(point)
        level.movingPlatforms.removeAll { $0.touches(point) }
    }

    private func updateMovingPlatform(start: LevelGridPoint, end: LevelGridPoint) {
        updateMovingPlatform(start: start, end: end, isLethal: selectedTool == .redMoving, recordsUndo: true)
    }

    private func updateMovingPlatform(start: LevelGridPoint, end: LevelGridPoint, isLethal: Bool, recordsUndo: Bool) {
        if recordsUndo {
            recordUndoSnapshot()
        }

        let safeStart = level.clamped(start)
        var safeEnd = level.clamped(end)
        if safeEnd == safeStart {
            safeEnd = defaultMovingEnd(from: safeStart)
        }

        level.tiles[safeStart] = nil
        level.tiles[safeEnd] = nil
        level.enemies.remove(safeStart)
        level.enemies.remove(safeEnd)

        if let index = level.movingPlatforms.firstIndex(where: { $0.start == safeStart || $0.end == safeStart }) {
            let baseStart = level.movingPlatforms[index].start
            if safeEnd == baseStart {
                safeEnd = defaultMovingEnd(from: baseStart)
            }
            level.tiles[baseStart] = nil
            level.movingPlatforms[index].end = safeEnd
            level.movingPlatforms[index].isLethal = isLethal
        } else {
            level.movingPlatforms.append(LevelMovingPlatform(start: safeStart, end: safeEnd, isLethal: isLethal))
        }

        persistCurrentLevel()
        playEditorSound(.platform)
    }

    private func defaultMovingEnd(from start: LevelGridPoint) -> LevelGridPoint {
        let xOffset = start.x < GameConstants.worldMaxX ? 1 : -1
        return level.clamped(LevelGridPoint(x: start.x + xOffset, y: start.y))
    }

    private func recordUndoSnapshot() {
        undoStack.append(level)
        if undoStack.count > GameConstants.maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func discardUnusedUndoSnapshot() {
        _ = undoStack.popLast()
    }

    private func undoEdit() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(level)
        level = previous
        persistCurrentLevel()
        playEditorSound(.select)
    }

    private func redoEdit() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(level)
        level = next
        persistCurrentLevel()
        playEditorSound(.select)
    }

    private func persistCurrentLevel() {
        guard levels.indices.contains(selectedLevelIndex) else { return }
        levels[selectedLevelIndex] = level
    }

    private func previousLevel() {
        selectLevel(selectedLevelIndex - 1)
    }

    private func nextLevel() {
        selectLevel(selectedLevelIndex + 1)
    }

    private func addLevel() {
        persistCurrentLevel()
        let newLevel = EditableLevel.empty()
        levels.append(newLevel)
        selectedLevelIndex = levels.count - 1
        loadLevel(newLevel)
        playEditorSound(.select)
    }

    private func saveCustomLevel() {
        persistCurrentLevel()
        if EditableLevel.saveCustomSet(levels) {
            playEditorSound(.select)
        } else {
            playEditorSound(.erase)
        }
    }

    private func selectLevel(_ index: Int) {
        guard levels.isEmpty == false else { return }
        let nextIndex = min(max(index, 0), levels.count - 1)
        guard nextIndex != selectedLevelIndex else { return }
        persistCurrentLevel()
        selectedLevelIndex = nextIndex
        loadLevel(levels[nextIndex])
        playEditorSound(.select)
    }

    private func loadLevel(_ nextLevel: EditableLevel) {
        level = nextLevel
        playState = LevelPlayState(level: level)
        isPlaying = false
        isPressingLeft = false
        isPressingRight = false
        queuedJump = false
        lastTickDate = nil
        undoStack.removeAll()
        redoStack.removeAll()
        camera = clampedCamera(x: 0, y: 3)
    }

    private func togglePlay() {
        if isPlaying {
            isPlaying = false
            isPressingLeft = false
            isPressingRight = false
            queuedJump = false
            lastTickDate = nil
            return
        }

        persistCurrentLevel()
        playState = LevelPlayState(level: level)
        isPlaying = true
        lastTickDate = nil
        snapCamera(on: CGPoint(x: playState.playerX, y: playState.playerY))
    }

    private func removeAll() {
        recordUndoSnapshot()
        level = EditableLevel.empty()
        selectedTool = .block
        zoom = 1.0
        camera = clampedCamera(x: 0, y: 3, atZoom: 1.0)
        playState = LevelPlayState(level: level)
        isPlaying = false
        persistCurrentLevel()
        playEditorSound(.erase)
    }

    private func moveCameraByDrag(dx: CGFloat, dy: CGFloat) {
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return }
        camera = clampedCamera(x: camera.x + dx, y: camera.y + dy)
    }

    private func zoomIn() {
        setZoom(zoom * 1.16)
    }

    private func zoomOut() {
        setZoom(zoom / 1.16)
    }

    private func setZoom(_ nextZoom: CGFloat) {
        let currentVisible = visibleWorldSize(atZoom: zoom)
        let center = CGPoint(
            x: camera.x + currentVisible.width / 2,
            y: camera.y + currentVisible.height / 2
        )
        let clampedZoom = min(max(nextZoom, GameConstants.minZoom), GameConstants.maxZoom)
        let nextVisible = visibleWorldSize(atZoom: clampedZoom)
        zoom = clampedZoom
        camera = clampedCamera(
            x: center.x - nextVisible.width / 2,
            y: center.y - nextVisible.height / 2,
            atZoom: clampedZoom
        )
    }

    private func snapCamera(on point: CGPoint) {
        let visible = visibleWorldSize(atZoom: zoom)
        camera = clampedCamera(
            x: point.x - visible.width / 2,
            y: point.y - visible.height / 2
        )
    }

    private func centerCamera(on point: CGPoint) {
        let visible = visibleWorldSize(atZoom: zoom)
        let target = clampedCamera(
            x: point.x - visible.width / 2,
            y: point.y - visible.height / 2
        )
        let distanceX = target.x - camera.x
        let distanceY = target.y - camera.y
        let distance = sqrt(distanceX * distanceX + distanceY * distanceY)
        let follow: CGFloat = distance > 5 ? 0.68 : 0.38
        camera = clampedCamera(
            x: camera.x + (target.x - camera.x) * follow,
            y: camera.y + (target.y - camera.y) * follow
        )
    }

    private func visibleWorldSize(atZoom cameraZoom: CGFloat) -> CGSize {
        CGSize(
            width: CGFloat(GameConstants.viewportColumns) / cameraZoom,
            height: CGFloat(GameConstants.viewportRows) / cameraZoom
        )
    }

    private func clampedCamera(x: CGFloat, y: CGFloat, atZoom cameraZoom: CGFloat? = nil) -> CGPoint {
        let activeZoom = cameraZoom ?? zoom
        let visible = visibleWorldSize(atZoom: activeZoom)
        let minX = CGFloat(GameConstants.worldMinX)
        let minY = CGFloat(GameConstants.worldMinY)
        let maxX = CGFloat(GameConstants.worldMaxX) - visible.width
        let maxY = CGFloat(GameConstants.worldMaxY) - visible.height
        return CGPoint(
            x: min(max(x, minX), maxX),
            y: min(max(y, minY), maxY)
        )
    }

    private func playEditorSound(for tool: CreatorTool) {
        switch tool {
        case .delete:
            playEditorSound(.erase)
        case .jumpPad:
            playEditorSound(.jumpPad)
        case .moving, .redMoving:
            playEditorSound(.platform)
        default:
            playEditorSound(.place)
        }
    }

    private func playEditorSound(_ sound: EditorSound) {
        AudioServicesPlaySystemSound(sound.systemSoundID)
    }

    private func stepPlay(deltaTime: CGFloat) {
        guard playState.isComplete == false else { return }

        var state = playState
        state.attackCooldown = max(0, state.attackCooldown - deltaTime)
        state.attackFlash = max(0, state.attackFlash - deltaTime)
        state.invulnerability = max(0, state.invulnerability - deltaTime)
        state.jumpBuffer = queuedJump ? GameConstants.jumpBufferTime : max(0, state.jumpBuffer - deltaTime)
        state.groundGrace = state.isGrounded ? GameConstants.coyoteTime : max(0, state.groundGrace - deltaTime)
        state.dreamExitGrace = max(0, state.dreamExitGrace - deltaTime)
        state.dreamBypass = max(0, state.dreamBypass - deltaTime)
        queuedJump = false

        for index in state.platforms.indices {
            state.platforms[index].advance(deltaTime: deltaTime)
        }
        carryPlayerIfStanding(on: &state)

        let movement = (isPressingRight ? CGFloat(1) : 0) - (isPressingLeft ? CGFloat(1) : 0)
        if movement != 0 {
            state.facing = movement
        }

        var speed = GameConstants.playerSpeed
        let foot = LevelGridPoint(x: Int(state.playerX.rounded(.down)), y: Int((state.playerY + 0.45).rounded(.down)))
        let currentTile = level.tiles[foot]
        let isInWater = touchesTile(kind: .water, state: state)
        let isTouchingSpace = currentTile == .space || touchesTile(kind: .space, state: state)
        let isInSpace = isTouchingSpace && state.dreamBypass <= 0
        let isOnIce = currentTile == .ice
        let isInMud = currentTile == .mud || touchesTile(kind: .mud, state: state)
        let justEnteredSpace = isInSpace && state.wasInSpace == false

        if isInSpace {
            if justEnteredSpace {
                let direction = dreamDirection(for: state, movement: movement)
                state.dreamDirectionX = direction.x
                state.dreamDirectionY = direction.y
            }
            state.facing = state.dreamDirectionX == 0 ? state.facing : (state.dreamDirectionX > 0 ? 1 : -1)
            state.velocityX = state.dreamDirectionX * GameConstants.spaceDreamSpeed
            state.velocityY = state.dreamDirectionY * GameConstants.spaceDreamSpeed
            state.isGrounded = false
            state.groundGrace = 0
            state.statusText = justEnteredSpace ? "Dream entry" : "Dream rush"
        }

        if isInSpace == false && isInWater {
            speed = max(speed, GameConstants.waterMoveSpeed)
            if state.velocityY > GameConstants.waterFloatVelocity {
                state.velocityY -= GameConstants.waterBuoyancy * deltaTime
            }
            state.velocityY = min(state.velocityY, GameConstants.waterMaxFallSpeed)
            state.statusText = "Floating"
        }

        if isInSpace == false && isOnIce {
            speed = max(speed, GameConstants.iceSpeed)
            state.statusText = "Ice slide"
        }

        if isInSpace == false && isInMud {
            speed = min(speed, GameConstants.mudSpeed)
            state.statusText = "Mud slow"
        }

        if isInSpace == false && currentTile == .conveyorLeft {
            state.velocityX -= GameConstants.conveyorPush * deltaTime
            state.statusText = "Conveyor"
        } else if isInSpace == false && currentTile == .conveyorRight {
            state.velocityX += GameConstants.conveyorPush * deltaTime
            state.statusText = "Conveyor"
        }

        if isInSpace == false && movement == 0 {
            state.velocityX *= isOnIce ? GameConstants.iceFriction : GameConstants.groundFriction
            if abs(state.velocityX) < 0.04 {
                state.velocityX = 0
            }
        } else if isInSpace == false {
            state.velocityX = movement * speed
        }

        if state.jumpBuffer > 0 && (state.isGrounded || state.groundGrace > 0 || isInWater || isInSpace || state.dreamExitGrace > 0) {
            if isInSpace {
                state.velocityX = state.dreamDirectionX * GameConstants.spaceExitSpeed
                state.velocityY = -GameConstants.spaceLaunchVelocity
                state.dreamExitGrace = GameConstants.dreamExitGrace
                state.dreamBypass = GameConstants.dreamJumpBypassTime
            } else if state.dreamExitGrace > 0 {
                state.velocityX = state.dreamDirectionX * GameConstants.spaceExitSpeed
                state.velocityY = -GameConstants.spaceLaunchVelocity
            } else {
                state.velocityY = isInWater && state.isGrounded == false ? -GameConstants.waterJumpVelocity : -GameConstants.jumpVelocity
            }
            state.isGrounded = false
            state.groundGrace = 0
            state.jumpBuffer = 0
            state.statusText = (isInSpace || state.dreamExitGrace > 0) ? "Dream jump" : (isInWater ? "Swim" : "Jump")
        }

        if isInSpace == false {
            state.velocityY += (isInWater ? GameConstants.waterGravity : GameConstants.gravity) * deltaTime
        }

        movePlayer(&state, deltaTime: deltaTime)
        handleJumpPads(&state)
        handleFeatureTiles(&state)
        updateTurrets(&state, deltaTime: deltaTime)
        moveProjectiles(&state, deltaTime: deltaTime)
        moveEnemies(&state, deltaTime: deltaTime)
        handleHazards(&state)
        handleProjectileContact(&state)
        handleEnemyContact(&state)
        handleGoal(&state)

        let respawnBaseY = CGFloat((state.checkpoint ?? level.start).y + GameConstants.fallRespawnOffset)
        if state.playerY > respawnBaseY {
            state = respawnState(message: "Respawned", previous: state)
        }

        let isStillInSpace = touchesTile(kind: .space, state: state) && state.dreamBypass <= 0
        if state.wasInSpace && isStillInSpace == false {
            state.dreamExitGrace = max(state.dreamExitGrace, GameConstants.dreamExitGrace)
        }
        state.wasInSpace = isStillInSpace
        playState = state
        centerCamera(on: CGPoint(x: state.playerX, y: state.playerY))
    }

    private func dreamDirection(for state: LevelPlayState, movement: CGFloat) -> CGPoint {
        var x = movement != 0 ? movement : state.facing
        var y: CGFloat = 0

        if abs(state.velocityX) > GameConstants.dreamEntryVelocityThreshold && movement == 0 {
            x = state.velocityX > 0 ? 1 : -1
        }
        if state.velocityY < -GameConstants.dreamEntryVelocityThreshold {
            y = -0.72
        } else if state.velocityY > GameConstants.dreamEntryVelocityThreshold {
            y = 0.42
        }

        let length = max(sqrt(x * x + y * y), 0.001)
        return CGPoint(x: x / length, y: y / length)
    }

    private func carryPlayerIfStanding(on state: inout LevelPlayState) {
        guard state.velocityY >= -0.1 else { return }

        let playerBottom = state.playerY + GameConstants.playerHeight / 2
        for platform in state.platforms where platform.isLethal == false {
            let top = platform.previousY - GameConstants.platformHeight / 2
            let withinX = abs(state.playerX - platform.previousX) < GameConstants.platformWidth * 0.62
            let standingOnTop = abs(playerBottom - top) < 0.18
            if withinX && standingOnTop {
                state.playerX += platform.deltaX
                state.playerY += platform.deltaY
                return
            }
        }
    }

    private func movePlayer(_ state: inout LevelPlayState, deltaTime: CGFloat) {
        let proposedX = state.playerX + state.velocityX * deltaTime
        if collides(centerX: proposedX, centerY: state.playerY, state: state) {
            state.velocityX = 0
        } else {
            state.playerX = proposedX
        }

        let proposedY = state.playerY + state.velocityY * deltaTime
        if collides(centerX: state.playerX, centerY: proposedY, state: state) {
            if state.velocityY > 0 {
                state.isGrounded = true
            }
            state.velocityY = 0
        } else {
            state.playerY = proposedY
            state.isGrounded = collides(centerX: state.playerX, centerY: state.playerY + 0.08, state: state)
        }
    }

    private func updateTurrets(_ state: inout LevelPlayState, deltaTime: CGFloat) {
        for point in Array(state.turretCooldowns.keys) {
            state.turretCooldowns[point] = max(0, (state.turretCooldowns[point] ?? 0) - deltaTime)
        }

        let player = CGPoint(x: state.playerX, y: state.playerY)
        for (point, tile) in level.tiles {
            guard tile == .turret || tile == .homingTurret else { continue }

            let origin = CGPoint(x: CGFloat(point.x) + 0.5, y: CGFloat(point.y) + 0.5)
            let distance = hypot(player.x - origin.x, player.y - origin.y)
            guard distance <= GameConstants.turretRange else { continue }
            guard (state.turretCooldowns[point] ?? 0) <= 0 else { continue }
            guard state.projectiles.count < GameConstants.maxProjectiles else { continue }

            let isHoming = tile == .homingTurret
            state.projectiles.append(LevelProjectileState(origin: origin, target: player, isHoming: isHoming))
            state.turretCooldowns[point] = isHoming ? GameConstants.homingTurretFireDelay : GameConstants.turretFireDelay
        }
    }

    private func moveProjectiles(_ state: inout LevelPlayState, deltaTime: CGFloat) {
        let player = CGPoint(x: state.playerX, y: state.playerY)
        for index in state.projectiles.indices {
            state.projectiles[index].advance(toward: player, deltaTime: deltaTime)
        }

        let hasKey = state.hasKey
        state.projectiles.removeAll { projectile in
            projectile.life <= 0 ||
                projectile.x < CGFloat(GameConstants.worldMinX) ||
                projectile.x > CGFloat(GameConstants.worldMaxX) ||
                projectile.y < CGFloat(GameConstants.worldMinY) ||
                projectile.y > CGFloat(GameConstants.worldMaxY) ||
                projectileHitsSolid(projectile, hasKey: hasKey)
        }
    }

    private func projectileHitsSolid(_ projectile: LevelProjectileState, hasKey: Bool) -> Bool {
        let point = LevelGridPoint(x: Int(projectile.x.rounded(.down)), y: Int(projectile.y.rounded(.down)))
        if point.x < GameConstants.worldMinX || point.x > GameConstants.worldMaxX || point.y > GameConstants.worldMaxY {
            return true
        }
        if point.y < GameConstants.worldMinY {
            return false
        }

        switch level.tiles[point] {
        case .block, .turret, .homingTurret:
            return true
        case .lock:
            return hasKey == false
        default:
            return false
        }
    }

    private func moveEnemies(_ state: inout LevelPlayState, deltaTime: CGFloat) {
        for index in state.enemies.indices {
            var enemy = state.enemies[index]
            let nextX = enemy.x + enemy.direction * GameConstants.enemySpeed * deltaTime
            let noseX = nextX + enemy.direction * 0.48
            let wallAhead = level.isSolid(at: LevelGridPoint(x: Int(noseX.rounded(.down)), y: Int(enemy.y.rounded(.down))))
            let floorAhead = level.isSolid(at: LevelGridPoint(x: Int(noseX.rounded(.down)), y: Int((enemy.y + 0.72).rounded(.down))))

            if wallAhead || floorAhead == false {
                enemy.direction *= -1
            } else {
                enemy.x = nextX
            }

            state.enemies[index] = enemy
        }
    }

    private func performAttack() {
        guard isPlaying, playState.attackCooldown <= 0 else { return }

        var state = playState
        state.attackCooldown = 0.34
        state.attackFlash = 0.18
        let reachX = state.playerX + state.facing * 1.08
        let playerY = state.playerY
        let before = state.enemies.count
        let projectileBefore = state.projectiles.count
        state.enemies.removeAll { enemy in
            abs(enemy.x - reachX) < 1.15 && abs(enemy.y - playerY) < 1.05
        }
        state.projectiles.removeAll { projectile in
            abs(projectile.x - reachX) < 1.15 && abs(projectile.y - playerY) < 0.95
        }
        state.statusText = (state.enemies.count < before || state.projectiles.count < projectileBefore) ? "Hit" : "Attack"
        playState = state
    }

    private func handleHazards(_ state: inout LevelPlayState) {
        if touchesTile(kind: .kill, state: state) {
            state = respawnState(message: "Kill block", previous: state)
            return
        }

        if touchesLethalPlatform(state: state) {
            state = respawnState(message: "Moving kill block", previous: state)
        }
    }

    private func handleJumpPads(_ state: inout LevelPlayState) {
        guard state.velocityY >= -1.0, let power = touchedJumpPadPower(state: state) else { return }
        state.velocityY = -power
        state.isGrounded = false
        state.statusText = "Jump pad"
        AudioServicesPlaySystemSound(EditorSound.jumpPad.systemSoundID)
    }

    private func handleFeatureTiles(_ state: inout LevelPlayState) {
        for point in touchedPoints(state: state) {
            guard let tile = level.tiles[point] else { continue }

            switch tile {
            case .spring:
                guard state.velocityY >= -1.0 else { continue }
                state.velocityY = -GameConstants.springVelocity
                state.isGrounded = false
                state.statusText = "Spring"
                AudioServicesPlaySystemSound(EditorSound.jumpPad.systemSoundID)
            case .checkpoint:
                if state.checkpoint != point {
                    state.checkpoint = point
                    state.statusText = "Checkpoint"
                    AudioServicesPlaySystemSound(EditorSound.select.systemSoundID)
                }
            case .heal:
                guard state.collectedItems.contains(point) == false else { continue }
                state.health = min(GameConstants.maxHealth, state.health + 1)
                state.collectedItems.insert(point)
                state.statusText = "Healed"
                AudioServicesPlaySystemSound(EditorSound.select.systemSoundID)
            case .coin:
                guard state.collectedItems.contains(point) == false else { continue }
                state.coins += 1
                state.collectedItems.insert(point)
                state.statusText = "Coin"
                AudioServicesPlaySystemSound(EditorSound.select.systemSoundID)
            case .key:
                guard state.collectedItems.contains(point) == false else { continue }
                state.hasKey = true
                state.collectedItems.insert(point)
                state.statusText = "Key"
                AudioServicesPlaySystemSound(EditorSound.select.systemSoundID)
            case .lock:
                if state.hasKey {
                    state.statusText = "Unlocked"
                }
            default:
                break
            }
        }
    }

    private func handleEnemyContact(_ state: inout LevelPlayState) {
        guard state.invulnerability <= 0 else { return }

        let touchedEnemy = state.enemies.contains { enemy in
            abs(enemy.x - state.playerX) < 0.72 && abs(enemy.y - state.playerY) < 0.76
        }

        guard touchedEnemy else { return }
        state.health -= 1
        state.invulnerability = 1.0
        state.velocityY = -5.2
        state.velocityX = -state.facing * 2.8
        state.statusText = "Enemy contact"

        if state.health <= 0 {
            state = respawnState(message: "Respawned", previous: state)
        }
    }

    private func handleProjectileContact(_ state: inout LevelPlayState) {
        let rect = playerRect(centerX: state.playerX, centerY: state.playerY)
        guard let hitIndex = state.projectiles.firstIndex(where: { rect.intersects($0.collisionRect) }) else { return }
        state.projectiles.remove(at: hitIndex)
        guard state.invulnerability <= 0 else { return }

        state.health -= 1
        state.invulnerability = 1.0
        state.velocityY = -4.6
        state.velocityX = -state.facing * 2.4
        state.statusText = "Turret hit"

        if state.health <= 0 {
            state = respawnState(message: "Respawned", previous: state)
        }
    }

    private func handleGoal(_ state: inout LevelPlayState) {
        let goalX = CGFloat(level.end.x) + 0.5
        let goalY = CGFloat(level.end.y) + 0.5
        if abs(state.playerX - goalX) < 0.78 && abs(state.playerY - goalY) < 0.92 {
            state.isComplete = true
            state.statusText = "Level complete"
        }
    }

    private func respawnState(message: String, previous: LevelPlayState? = nil) -> LevelPlayState {
        var state = LevelPlayState(level: level)
        if let previous {
            state.coins = previous.coins
            state.hasKey = previous.hasKey
            state.collectedItems = previous.collectedItems
            state.checkpoint = previous.checkpoint
            if let checkpoint = previous.checkpoint {
                state.playerX = CGFloat(checkpoint.x) + 0.5
                state.playerY = CGFloat(checkpoint.y) + 0.38
            }
        }
        state.statusText = message
        return state
    }

    private func touchedJumpPadPower(state: LevelPlayState) -> CGFloat? {
        var power: CGFloat?
        for point in touchedPoints(state: state) {
            if case let .jumpPad(padPower) = level.tiles[point] {
                power = max(power ?? padPower, padPower)
            }
        }
        return power
    }

    private func touchedPoints(state: LevelPlayState) -> [LevelGridPoint] {
        let halfWidth = GameConstants.playerWidth / 2
        let halfHeight = GameConstants.playerHeight / 2
        let left = Int((state.playerX - halfWidth).rounded(.down))
        let right = Int((state.playerX + halfWidth).rounded(.down))
        let top = Int((state.playerY - halfHeight).rounded(.down))
        let bottom = Int((state.playerY + halfHeight).rounded(.down))
        var points: [LevelGridPoint] = []

        for y in top...bottom {
            for x in left...right {
                points.append(LevelGridPoint(x: x, y: y))
            }
        }

        return points
    }

    private func touchesTile(kind: LevelTileKind, state: LevelPlayState) -> Bool {
        for point in touchedPoints(state: state) {
            if level.tiles[point] == kind {
                return true
            }
        }

        return false
    }

    private func touchesLethalPlatform(state: LevelPlayState) -> Bool {
        let rect = playerRect(centerX: state.playerX, centerY: state.playerY)
        return state.platforms.contains { platform in
            platform.isLethal && rect.intersects(platform.collisionRect)
        }
    }

    private func collides(centerX: CGFloat, centerY: CGFloat, state: LevelPlayState) -> Bool {
        let playerRect = playerRect(centerX: centerX, centerY: centerY)
        let left = Int(playerRect.minX.rounded(.down))
        let right = Int(playerRect.maxX.rounded(.down))
        let top = Int(playerRect.minY.rounded(.down))
        let bottom = Int(playerRect.maxY.rounded(.down))

        for y in top...bottom {
            for x in left...right {
                if isSolid(at: LevelGridPoint(x: x, y: y), state: state) {
                    return true
                }
            }
        }

        for platform in state.platforms where platform.isLethal == false {
            if playerRect.intersects(platform.collisionRect) {
                return true
            }
        }

        return false
    }

    private func playerRect(centerX: CGFloat, centerY: CGFloat) -> CGRect {
        let halfWidth = GameConstants.playerWidth / 2
        let halfHeight = GameConstants.playerHeight / 2
        return CGRect(
            x: centerX - halfWidth,
            y: centerY - halfHeight,
            width: GameConstants.playerWidth,
            height: GameConstants.playerHeight
        )
    }

    private func isSolid(at point: LevelGridPoint, state: LevelPlayState) -> Bool {
        if point.x < GameConstants.worldMinX || point.x > GameConstants.worldMaxX || point.y > GameConstants.worldMaxY {
            return true
        }

        if point.y < GameConstants.worldMinY {
            return false
        }

        guard let tile = level.tiles[point] else {
            return false
        }

        switch tile {
        case .block, .turret, .homingTurret:
            return true
        case .lock:
            return state.hasKey == false
        default:
            return false
        }
    }
}

private struct PlayHeartHUD: View {
    let health: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<GameConstants.maxHealth, id: \.self) { index in
                Image(systemName: index < health ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(index < health ? Color.redPop : Color.white.opacity(0.34))
                    .shadow(color: Color.black.opacity(0.34), radius: 4, y: 2)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(PremiumPanelBackground(cornerRadius: 8))
    }
}

private struct StatusStrip: View {
    let isPlaying: Bool
    let selectedTool: CreatorTool
    let level: EditableLevel
    let playState: LevelPlayState

    var body: some View {
        HStack(spacing: 8) {
            Badge(
                symbol: isPlaying ? "gamecontroller.fill" : selectedTool.symbolName,
                text: isPlaying ? playState.statusText : selectedTool.title,
                tint: isPlaying ? Color.sky : selectedTool.tint
            )
            .layoutPriority(1)

            Spacer(minLength: 4)

            if isPlaying {
                Badge(symbol: "heart.fill", text: "\(playState.health)", tint: Color.redPop)
                Badge(symbol: "circle.fill", text: "\(playState.coins)", tint: Color.gold)
                if playState.hasKey {
                    Badge(symbol: "key.fill", text: "Key", tint: Color.mintPop)
                }
                Badge(symbol: "bolt.fill", text: "\(playState.enemies.count)", tint: Color.violetSoft)
            } else {
                Badge(symbol: "square.grid.3x3.fill", text: "\(level.tiles.count)", tint: Color.sky)
                Badge(symbol: "arrow.left.and.right", text: "\(level.movingPlatforms.count)", tint: Color.purplePop)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(PremiumPanelBackground(cornerRadius: 8))
    }
}

private struct LevelControls: View {
    let levelIndex: Int
    let levelCount: Int
    let previousAction: () -> Void
    let nextAction: () -> Void
    let addAction: () -> Void
    let saveAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            CompactIconButton(symbol: "chevron.left", isEnabled: levelIndex > 0, action: previousAction)

            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color.sky)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Level \(levelIndex + 1)")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                    Text("\(levelCount) slots")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.48))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(PremiumPanelBackground(cornerRadius: 8))

            CompactIconButton(symbol: "chevron.right", isEnabled: levelIndex < levelCount - 1, action: nextAction)
            CompactIconButton(symbol: "plus", isEnabled: true, action: addAction)
            CompactIconButton(symbol: "tray.and.arrow.down.fill", isEnabled: true, action: saveAction)
        }
    }
}

private struct CompactIconButton: View {
    let symbol: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .black))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(SecondaryButtonStyle())
        .opacity(isEnabled ? 1 : 0.38)
        .disabled(isEnabled == false)
    }
}

private struct PremiumPanelBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.105),
                        Color.white.opacity(0.045)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.2), radius: 10, y: 5)
    }
}

private struct Badge: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(tint)

            Text(text)
                .font(.caption.weight(.black))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct LevelCanvasView: View {
    @State private var lastPaintedPoint: LevelGridPoint?
    @State private var lastCameraTranslation = CGSize.zero
    @State private var hasRecordedMovingDrag = false

    let level: EditableLevel
    let selectedTool: CreatorTool
    let camera: CGPoint
    let zoom: CGFloat
    let isPlaying: Bool
    let playState: LevelPlayState
    let applyAction: (LevelGridPoint) -> Void
    let movingDragAction: (LevelGridPoint, LevelGridPoint, Bool) -> Void
    let cameraDragAction: (CGFloat, CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            let metrics = ViewportMetrics(availableSize: proxy.size, zoom: zoom)

            ZStack {
                board(metrics: metrics)
                    .frame(width: metrics.boardWidth, height: metrics.boardHeight)
                    .shadow(color: Color.black.opacity(0.42), radius: 20, y: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func board(metrics: ViewportMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.055, green: 0.065, blue: 0.08), Color(red: 0.08, green: 0.1, blue: 0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            ForEach(visibleRows(), id: \.self) { row in
                ForEach(visibleColumns(), id: \.self) { column in
                    let point = LevelGridPoint(x: column, y: row)
                    TileCell(
                        point: point,
                        tile: tileForDisplay(at: point),
                        isStart: point == level.start,
                        isEnd: point == level.end,
                        hasEnemy: level.enemies.contains(point),
                        isMoveTool: selectedTool == .move
                    )
                    .frame(width: metrics.cellSize, height: metrics.cellSize)
                    .position(
                        x: pointCenter(point, metrics: metrics).x,
                        y: pointCenter(point, metrics: metrics).y
                    )
                }
            }

            ForEach(level.movingPlatforms) { platform in
                if lineIsVisible(platform) {
                    movingPath(platform, metrics: metrics)
                }
            }

            if isPlaying {
                ForEach(playState.platforms) { platform in
                    if isVisible(x: platform.x, y: platform.y) {
                        MovingPlatformView(isLethal: platform.isLethal)
                            .frame(width: metrics.cellSize * GameConstants.platformWidth, height: metrics.cellSize * GameConstants.platformHeight)
                            .position(
                                x: (platform.x - camera.x) * metrics.cellSize,
                                y: (platform.y - camera.y) * metrics.cellSize
                            )
                    }
                }

                ForEach(playState.enemies) { enemy in
                    if isVisible(x: enemy.x, y: enemy.y) {
                        EnemyView(direction: enemy.direction)
                            .frame(width: metrics.cellSize * 0.78, height: metrics.cellSize * 0.78)
                            .position(
                                x: (enemy.x - camera.x) * metrics.cellSize,
                                y: (enemy.y - camera.y) * metrics.cellSize
                            )
                    }
                }

                ForEach(playState.projectiles) { projectile in
                    if isVisible(x: projectile.x, y: projectile.y) {
                        ProjectileView(isHoming: projectile.isHoming)
                            .frame(width: metrics.cellSize * 0.34, height: metrics.cellSize * 0.34)
                            .position(
                                x: (projectile.x - camera.x) * metrics.cellSize,
                                y: (projectile.y - camera.y) * metrics.cellSize
                            )
                    }
                }

                if isVisible(x: playState.playerX, y: playState.playerY) {
                    PlayerView(
                        facing: playState.facing,
                        isInvulnerable: playState.invulnerability > 0,
                        isAttacking: playState.attackFlash > 0
                    )
                    .frame(width: metrics.cellSize * 0.78, height: metrics.cellSize * 0.92)
                    .position(
                        x: (playState.playerX - camera.x) * metrics.cellSize,
                        y: (playState.playerY - camera.y) * metrics.cellSize
                    )
                }
            } else {
                ForEach(level.movingPlatforms) { platform in
                    if isVisible(point: platform.start) {
                        MovingPlatformView(isLethal: platform.isLethal)
                            .frame(width: metrics.cellSize * GameConstants.platformWidth, height: metrics.cellSize * GameConstants.platformHeight)
                            .position(
                                x: pointCenter(platform.start, metrics: metrics).x,
                                y: pointCenter(platform.start, metrics: metrics).y
                            )
                    }

                    if isVisible(point: platform.end) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: max(16, metrics.cellSize * 0.58), weight: .black))
                            .foregroundStyle(platform.tint)
                            .rotationEffect(angle(for: platform))
                            .shadow(color: platform.tint.opacity(0.45), radius: 8)
                            .position(
                                x: pointCenter(platform.end, metrics: metrics).x,
                                y: pointCenter(platform.end, metrics: metrics).y
                            )
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard isPlaying == false else { return }

                    if selectedTool == .move {
                        let deltaX = value.translation.width - lastCameraTranslation.width
                        let deltaY = value.translation.height - lastCameraTranslation.height
                        if abs(deltaX) > 0.1 || abs(deltaY) > 0.1 {
                            cameraDragAction(-deltaX / max(metrics.cellSize, 1), -deltaY / max(metrics.cellSize, 1))
                            lastCameraTranslation = value.translation
                        }
                        return
                    }

                    if selectedTool.isMovingPlatformTool {
                        guard abs(value.translation.width) > 9 || abs(value.translation.height) > 9 else { return }
                        movingDragAction(
                            point(for: value.startLocation, cellSize: metrics.cellSize),
                            point(for: value.location, cellSize: metrics.cellSize),
                            hasRecordedMovingDrag == false
                        )
                        hasRecordedMovingDrag = true
                        return
                    }

                    guard selectedTool.supportsDragPainting else { return }
                    let point = point(for: value.location, cellSize: metrics.cellSize)
                    if point != lastPaintedPoint {
                        applyAction(point)
                        lastPaintedPoint = point
                    }
                }
                .onEnded { value in
                    guard isPlaying == false else { return }
                    defer {
                        lastPaintedPoint = nil
                        lastCameraTranslation = .zero
                        hasRecordedMovingDrag = false
                    }

                    if selectedTool == .move {
                        return
                    } else if selectedTool.isMovingPlatformTool && (abs(value.translation.width) > 9 || abs(value.translation.height) > 9) {
                        movingDragAction(
                            point(for: value.startLocation, cellSize: metrics.cellSize),
                            point(for: value.location, cellSize: metrics.cellSize),
                            hasRecordedMovingDrag == false
                        )
                    } else if selectedTool.supportsDragPainting {
                        let point = point(for: value.location, cellSize: metrics.cellSize)
                        if point != lastPaintedPoint {
                            applyAction(point)
                        }
                    } else {
                        applyAction(point(for: value.location, cellSize: metrics.cellSize))
                    }
                }
        )
    }

    private func movingPath(_ platform: LevelMovingPlatform, metrics: ViewportMetrics) -> some View {
        let start = pointCenter(platform.start, metrics: metrics)
        let end = pointCenter(platform.end, metrics: metrics)
        return Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(
            platform.tint.opacity(isPlaying ? 0.32 : 0.72),
            style: StrokeStyle(lineWidth: max(2, metrics.cellSize * 0.12), lineCap: .round, dash: isPlaying ? [6, 8] : [])
        )
    }

    private func visibleColumns() -> [Int] {
        visibleIndices(start: camera.x, span: visibleColumnSpan, lowerLimit: GameConstants.worldMinX, upperLimit: GameConstants.worldMaxX)
    }

    private func tileForDisplay(at point: LevelGridPoint) -> LevelTileKind? {
        if isPlaying && playState.collectedItems.contains(point) {
            return nil
        }

        return level.tiles[point]
    }

    private func visibleRows() -> [Int] {
        visibleIndices(start: camera.y, span: visibleRowSpan, lowerLimit: GameConstants.worldMinY, upperLimit: GameConstants.worldMaxY)
    }

    private var visibleColumnSpan: CGFloat {
        CGFloat(GameConstants.viewportColumns) / zoom
    }

    private var visibleRowSpan: CGFloat {
        CGFloat(GameConstants.viewportRows) / zoom
    }

    private func visibleIndices(start: CGFloat, span: CGFloat, lowerLimit: Int, upperLimit: Int) -> [Int] {
        let lower = max(lowerLimit, Int(start.rounded(.down)) - 1)
        let upper = min(upperLimit, Int((start + span).rounded(.up)) + 1)
        guard lower <= upper else { return [] }
        return Array(lower...upper)
    }

    private func point(for location: CGPoint, cellSize: CGFloat) -> LevelGridPoint {
        let x = Int((camera.x + location.x / max(cellSize, 1)).rounded(.down))
        let y = Int((camera.y + location.y / max(cellSize, 1)).rounded(.down))
        return level.clamped(LevelGridPoint(x: x, y: y))
    }

    private func pointCenter(_ point: LevelGridPoint, metrics: ViewportMetrics) -> CGPoint {
        CGPoint(
            x: (CGFloat(point.x) - camera.x) * metrics.cellSize + metrics.cellSize / 2,
            y: (CGFloat(point.y) - camera.y) * metrics.cellSize + metrics.cellSize / 2
        )
    }

    private func angle(for platform: LevelMovingPlatform) -> Angle {
        let dx = Double(platform.end.x - platform.start.x)
        let dy = Double(platform.end.y - platform.start.y)
        return Angle(radians: atan2(dy, dx))
    }

    private func lineIsVisible(_ platform: LevelMovingPlatform) -> Bool {
        isVisible(point: platform.start) || isVisible(point: platform.end)
    }

    private func isVisible(point: LevelGridPoint) -> Bool {
        CGFloat(point.x) >= camera.x - 1 &&
            CGFloat(point.x) <= camera.x + visibleColumnSpan + 1 &&
            CGFloat(point.y) >= camera.y - 1 &&
            CGFloat(point.y) <= camera.y + visibleRowSpan + 1
    }

    private func isVisible(x: CGFloat, y: CGFloat) -> Bool {
        x >= camera.x - 1 &&
            x <= camera.x + visibleColumnSpan + 1 &&
            y >= camera.y - 1 &&
            y <= camera.y + visibleRowSpan + 1
    }
}

private struct TileCell: View {
    let point: LevelGridPoint
    let tile: LevelTileKind?
    let isStart: Bool
    let isEnd: Bool
    let hasEnemy: Bool
    let isMoveTool: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(baseFill)
                .overlay(alignment: .bottom) {
                    if tile == .water {
                        Rectangle()
                            .fill(Color.white.opacity(0.13))
                            .frame(height: 3)
                    }
                }

            if tile == .space {
                SpaceBlockTexture(point: point)
            }

            if let tile = tile {
                Image(systemName: tile.symbolName)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tile.foregroundColor)
                    .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
            }

            if isStart {
                Image(systemName: "flag.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color.mintPop)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
            }

            if isEnd {
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color.gold)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
            }

            if hasEnemy {
                Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color.redPop)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .overlay {
            Rectangle()
                .stroke(isMoveTool ? Color.white.opacity(0.16) : Color.white.opacity(0.07), lineWidth: 0.7)
        }
        .animation(.spring(response: 0.16, dampingFraction: 0.82), value: tile)
        .animation(.spring(response: 0.16, dampingFraction: 0.82), value: isStart)
        .animation(.spring(response: 0.16, dampingFraction: 0.82), value: isEnd)
        .animation(.spring(response: 0.16, dampingFraction: 0.82), value: hasEnemy)
    }

    private var baseFill: Color {
        if let tile = tile {
            return tile.fillColor
        }

        return (point.x + point.y).isMultiple(of: 2)
            ? Color.white.opacity(0.035)
            : Color.white.opacity(0.022)
    }
}

private struct SpaceBlockTexture: View {
    let point: LevelGridPoint

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.04, blue: 0.18),
                        Color(red: 0.08, green: 0.18, blue: 0.38),
                        Color(red: 0.26, green: 0.12, blue: 0.42)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                ForEach(0..<7, id: \.self) { index in
                    Circle()
                        .fill(index.isMultiple(of: 3) ? Color.gold.opacity(0.86) : Color.white.opacity(0.72))
                        .frame(width: starSize(index), height: starSize(index))
                        .position(starPosition(index, in: proxy.size))
                }

                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: proxy.size.width * 0.68, height: max(1.4, proxy.size.height * 0.07))
                    .rotationEffect(.degrees(-32))
                    .offset(x: -proxy.size.width * 0.08, y: proxy.size.height * 0.1)
            }
        }
    }

    private func starSize(_ index: Int) -> CGFloat {
        CGFloat(2 + abs(point.x * 13 + point.y * 7 + index * 5) % 4)
    }

    private func starPosition(_ index: Int, in size: CGSize) -> CGPoint {
        let seed = abs(point.x * 41 + point.y * 29 + index * 53)
        let x = CGFloat((seed % 82) + 9) / 100
        let y = CGFloat(((seed / 7) % 82) + 9) / 100
        return CGPoint(x: size.width * x, y: size.height * y)
    }
}

private struct PlayerView: View {
    let facing: CGFloat
    let isInvulnerable: Bool
    let isAttacking: Bool

    var body: some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.mintPop, Color.sky],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(isInvulnerable ? 0.68 : 0.28), lineWidth: 2)
                }

            Circle()
                .fill(Color.black.opacity(0.42))
                .frame(width: 6, height: 6)
                .offset(x: facing >= 0 ? 7 : -7, y: -8)

            if isAttacking {
                Capsule()
                    .fill(Color.gold.opacity(0.9))
                    .frame(width: 30, height: 8)
                    .offset(x: facing >= 0 ? 24 : -24, y: 0)
            }
        }
        .opacity(isInvulnerable ? 0.68 : 1)
    }
}

private struct EnemyView: View {
    let direction: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.redPop, Color.violetSoft],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: "exclamationmark")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .offset(x: direction >= 0 ? 2 : -2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct ProjectileView: View {
    let isHoming: Bool

    var body: some View {
        Circle()
            .fill(isHoming ? Color.sky : Color.gold)
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: (isHoming ? Color.sky : Color.gold).opacity(0.62), radius: 8)
    }
}

private struct MovingPlatformView: View {
    let isLethal: Bool

    private var colors: [Color] {
        isLethal
            ? [Color.redPop, Color(red: 0.68, green: 0.04, blue: 0.08)]
            : [Color.purplePop, Color(red: 0.55, green: 0.28, blue: 1.0)]
    }

    private var shadowTint: Color {
        isLethal ? Color.redPop : Color.purplePop
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .shadow(color: shadowTint.opacity(0.42), radius: 9, y: 4)
    }
}

private struct EditorControls: View {
    @Binding var selectedTool: CreatorTool
    let hotbarTools: [CreatorTool]
    @Binding var jumpPadPower: CGFloat
    let camera: CGPoint
    let zoom: CGFloat
    let canUndo: Bool
    let canRedo: Bool
    let undoAction: () -> Void
    let redoAction: () -> Void
    let libraryAction: () -> Void
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let removeAllAction: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(hotbarTools) { tool in
                        Button {
                            selectedTool = tool
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: tool.symbolName)
                                    .font(.system(size: 17, weight: .black))
                                Text(tool.title)
                                    .font(.caption2.weight(.black))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                            }
                            .frame(width: 68, height: 54)
                        }
                        .buttonStyle(ToolButtonStyle(tint: tool.tint, isSelected: selectedTool == tool))
                    }
                }
                .padding(.horizontal, 2)
            }

            if selectedTool == .jumpPad {
                JumpPadSettings(power: $jumpPadPower)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                CompactIconButton(symbol: "arrow.uturn.backward", isEnabled: canUndo, action: undoAction)
                CompactIconButton(symbol: "arrow.uturn.forward", isEnabled: canRedo, action: redoAction)

                Button(action: libraryAction) {
                    Label("Library", systemImage: "square.grid.2x2.fill")
                        .font(.caption.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(height: 34)
                }
                .buttonStyle(SecondaryButtonStyle())

                Label("Move", systemImage: "hand.draw.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("\(Int(camera.x.rounded())),\(Int(camera.y.rounded()))")
                    .font(.caption2.weight(.black).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(minWidth: 40)

                Spacer(minLength: 0)

                HStack(spacing: 3) {
                    Button(action: zoomOutAction) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.caption2.weight(.black).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 42)

                    Button(action: zoomInAction) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button(action: removeAllAction) {
                    Label("Remove All", systemImage: "trash.fill")
                        .font(.caption.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(height: 34)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(10)
        .background(PremiumPanelBackground(cornerRadius: 8))
    }
}

private struct JumpPadSettings: View {
    @Binding var power: CGFloat

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(power) },
            set: { power = CGFloat($0) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Label("Pad", systemImage: "arrow.up.circle.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(Color.mintPop)
                .frame(width: 54, alignment: .leading)

            Slider(value: sliderValue, in: 12.0...24.0, step: 1.0)
                .tint(Color.mintPop)

            Text("\(Int(power.rounded()))")
                .font(.caption.weight(.black).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.mintPop.opacity(0.24), lineWidth: 1)
        }
    }
}

private struct BlockLibraryView: View {
    @Binding var selectedTool: CreatorTool
    @Binding var jumpPadPower: CGFloat
    @Binding var hotbarTools: [CreatorTool]
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 118), spacing: 10)
    ]

    var body: some View {
        ZStack {
            AppBackdrop()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block Library")
                            .font(.title2.weight(.black))
                            .foregroundStyle(.white)
                        Text("Pick a feature block, then paint it into the level.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.58))
                    }

                    Spacer(minLength: 0)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                JumpPadSettings(power: $jumpPadPower)

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(CreatorTool.blockLibraryTools) { tool in
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    selectedTool = tool
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Image(systemName: tool.symbolName)
                                                .font(.system(size: 18, weight: .black))
                                                .foregroundStyle(selectedTool == tool ? Color.black : tool.tint)
                                            Spacer(minLength: 0)
                                            if selectedTool == tool {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 13, weight: .black))
                                                    .foregroundStyle(Color.black.opacity(0.72))
                                            }
                                        }

                                        Text(tool.title)
                                            .font(.caption.weight(.black))
                                            .foregroundStyle(selectedTool == tool ? Color.black : Color.white)
                                            .lineLimit(1)

                                        Text(tool.featureText)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(selectedTool == tool ? Color.black.opacity(0.62) : Color.white.opacity(0.52))
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .buttonStyle(.plain)

                                Button {
                                    toggleHotbar(tool)
                                } label: {
                                    Label(hotbarTools.contains(tool) ? "Remove" : "Add to Hotbar", systemImage: hotbarTools.contains(tool) ? "minus.square.fill" : "plus.square.fill")
                                        .font(.caption.weight(.black))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.74)
                                        .frame(maxWidth: .infinity, minHeight: 30)
                                }
                                .buttonStyle(ToolButtonStyle(tint: tool.tint, isSelected: hotbarTools.contains(tool)))
                            }
                            .padding(10)
                            .frame(minHeight: 140, alignment: .topLeading)
                            .background(
                                selectedTool == tool
                                    ? tool.tint
                                    : Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selectedTool == tool ? Color.white.opacity(0.4) : tool.tint.opacity(0.2), lineWidth: 1)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }

    private func toggleHotbar(_ tool: CreatorTool) {
        if let index = hotbarTools.firstIndex(of: tool) {
            guard hotbarTools.count > 1 else { return }
            hotbarTools.remove(at: index)
            if selectedTool == tool {
                selectedTool = hotbarTools.first ?? .block
            }
        } else {
            hotbarTools.append(tool)
        }
        AudioServicesPlaySystemSound(EditorSound.select.systemSoundID)
    }
}

private struct PlayControls: View {
    @Binding var isPressingLeft: Bool
    @Binding var isPressingRight: Bool
    let jumpAction: () -> Void
    let attackAction: () -> Void
    let createAction: () -> Void
    let canAttack: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    HoldButton(symbol: "chevron.left", title: "Left", isPressed: $isPressingLeft)
                    HoldButton(symbol: "chevron.right", title: "Right", isPressed: $isPressingRight)
                }

                Spacer(minLength: 8)

                InstantActionButton(
                    symbol: "arrow.up",
                    title: "Jump",
                    tint: Color.mintPop,
                    width: 76,
                    isEnabled: true,
                    action: jumpAction
                )

                InstantActionButton(
                    symbol: "burst.fill",
                    title: "Attack",
                    tint: Color.gold,
                    width: 84,
                    isEnabled: canAttack,
                    action: attackAction
                )
            }

            Button(action: createAction) {
                Label("Create", systemImage: "hammer.fill")
                    .font(.headline.weight(.black))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(GreenModeButtonStyle())
        }
        .padding(10)
        .background(PremiumPanelBackground(cornerRadius: 8))
    }
}

private struct InstantActionButton: View {
    let symbol: String
    let title: String
    let tint: Color
    let width: CGFloat
    let isEnabled: Bool
    let action: () -> Void

    @State private var isPressed = false
    @State private var didFire = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .black))
            Text(title)
                .font(.caption.weight(.black))
        }
        .foregroundStyle(isEnabled ? Color.black : Color.white.opacity(0.46))
        .frame(width: width, height: 58)
        .background(
            isEnabled
                ? tint.opacity(isPressed ? 0.78 : 0.96)
                : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(isEnabled ? 0.35 : 0.08), lineWidth: 1)
        }
        .scaleEffect(isPressed && isEnabled ? 0.97 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled else { return }
                    isPressed = true
                    if didFire == false {
                        didFire = true
                        action()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    didFire = false
                }
        )
        .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}

private struct HoldButton: View {
    let symbol: String
    let title: String
    @Binding var isPressed: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .black))
            Text(title)
                .font(.caption.weight(.black))
        }
        .foregroundStyle(.white)
        .frame(width: 70, height: 58)
        .background(isPressed ? Color.sky.opacity(0.86) : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isPressed ? Color.white.opacity(0.48) : Color.white.opacity(0.13), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if isPressed == false {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    isPressed = false
                }
        )
    }
}

private struct AppBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.043, blue: 0.054),
                    Color(red: 0.058, green: 0.083, blue: 0.088),
                    Color(red: 0.026, green: 0.028, blue: 0.036)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 18) {
                ForEach(0..<10, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.035 : 0.018))
                        .frame(height: 1)
                }
            }
            .padding(.horizontal, 18)
        }
        .ignoresSafeArea()
    }
}

private struct ViewportMetrics {
    let cellSize: CGFloat
    let boardWidth: CGFloat
    let boardHeight: CGFloat

    init(availableSize: CGSize, zoom: CGFloat) {
        let horizontalCell = availableSize.width / CGFloat(GameConstants.viewportColumns)
        let verticalCell = availableSize.height / CGFloat(GameConstants.viewportRows)
        let baseCellSize = max(18, min(horizontalCell, verticalCell).rounded(.down))
        cellSize = max(12, baseCellSize * zoom)
        boardWidth = baseCellSize * CGFloat(GameConstants.viewportColumns)
        boardHeight = baseCellSize * CGFloat(GameConstants.viewportRows)
    }
}

private enum GameConstants {
    static let worldMinX = -5000
    static let worldMaxX = 5000
    static let worldMinY = -500
    static let worldMaxY = 1200
    static let fallRespawnOffset = 35
    static let maxUndoLevels = 100
    static let viewportColumns = 18
    static let viewportRows = 11
    static let playerWidth: CGFloat = 0.64
    static let playerHeight: CGFloat = 0.86
    static let platformWidth: CGFloat = 0.96
    static let platformHeight: CGFloat = 0.68
    static let maxHealth = 3
    static let playerSpeed: CGFloat = 6.7
    static let spaceDreamSpeed: CGFloat = 13.8
    static let spaceExitSpeed: CGFloat = 15.2
    static let spaceLaunchVelocity: CGFloat = 12.4
    static let dreamExitGrace: CGFloat = 0.16
    static let dreamEntryVelocityThreshold: CGFloat = 1.2
    static let dreamJumpBypassTime: CGFloat = 0.18
    static let jumpBufferTime: CGFloat = 0.14
    static let coyoteTime: CGFloat = 0.1
    static let jumpVelocity: CGFloat = 13.6
    static let gravity: CGFloat = 23.0
    static let groundFriction: CGFloat = 0.72
    static let iceFriction: CGFloat = 0.94
    static let iceSpeed: CGFloat = 7.2
    static let mudSpeed: CGFloat = 3.7
    static let conveyorPush: CGFloat = 9.0
    static let springVelocity: CGFloat = 15.8
    static let waterGravity: CGFloat = 4.8
    static let waterBuoyancy: CGFloat = 11.5
    static let waterFloatVelocity: CGFloat = -0.45
    static let waterMaxFallSpeed: CGFloat = 0.75
    static let waterMoveSpeed: CGFloat = 5.9
    static let waterJumpVelocity: CGFloat = 7.2
    static let defaultJumpPadPower: CGFloat = 18.0
    static let enemySpeed: CGFloat = 1.7
    static let platformSpeed: CGFloat = 2.4
    static let turretRange: CGFloat = 13.0
    static let turretFireDelay: CGFloat = 1.2
    static let homingTurretFireDelay: CGFloat = 1.55
    static let turretProjectileSpeed: CGFloat = 8.8
    static let homingProjectileSpeed: CGFloat = 7.2
    static let homingTurnRate: CGFloat = 0.12
    static let projectileLife: CGFloat = 3.2
    static let projectileSize: CGFloat = 0.28
    static let projectileSpawnOffset: CGFloat = 0.92
    static let maxProjectiles = 28
    static let minZoom: CGFloat = 0.7
    static let maxZoom: CGFloat = 1.75
}

private enum EditorSound {
    case place
    case erase
    case platform
    case jumpPad
    case select

    var systemSoundID: SystemSoundID {
        switch self {
        case .place:
            return 1104
        case .erase:
            return 1155
        case .platform:
            return 1057
        case .jumpPad:
            return 1025
        case .select:
            return 1105
        }
    }
}

private struct EditableLevel: Codable {
    private static let customSetKey = "levelCreator.customLevels.v1"

    var tiles: [LevelGridPoint: LevelTileKind]
    var enemies: Set<LevelGridPoint>
    var movingPlatforms: [LevelMovingPlatform]
    var start: LevelGridPoint
    var end: LevelGridPoint

    static func savedSet() -> [EditableLevel] {
        guard
            let data = UserDefaults.standard.data(forKey: customSetKey),
            let savedLevels = try? JSONDecoder().decode([EditableLevel].self, from: data),
            savedLevels.isEmpty == false
        else {
            return defaultSet()
        }

        return savedLevels
    }

    @discardableResult
    static func saveCustomSet(_ levels: [EditableLevel]) -> Bool {
        guard let data = try? JSONEncoder().encode(levels) else {
            return false
        }

        UserDefaults.standard.set(data, forKey: customSetKey)
        return true
    }

    static func defaultSet() -> [EditableLevel] {
        [starter(), empty(), empty()]
    }

    static func starter() -> EditableLevel {
        return EditableLevel(
            tiles: [
                LevelGridPoint(x: 2, y: 14): .block,
                LevelGridPoint(x: 6, y: 13): .block,
                LevelGridPoint(x: 10, y: 12): .block
            ],
            enemies: [],
            movingPlatforms: [],
            start: LevelGridPoint(x: 2, y: 13),
            end: LevelGridPoint(x: 12, y: 11)
        )
    }

    static func empty() -> EditableLevel {
        EditableLevel(
            tiles: [:],
            enemies: [],
            movingPlatforms: [],
            start: LevelGridPoint(x: 2, y: 13),
            end: LevelGridPoint(x: 12, y: 11)
        )
    }

    func contains(_ point: LevelGridPoint) -> Bool {
        point.x >= GameConstants.worldMinX &&
            point.x <= GameConstants.worldMaxX &&
            point.y >= GameConstants.worldMinY &&
            point.y <= GameConstants.worldMaxY
    }

    func clamped(_ point: LevelGridPoint) -> LevelGridPoint {
        LevelGridPoint(
            x: min(max(point.x, GameConstants.worldMinX), GameConstants.worldMaxX),
            y: min(max(point.y, GameConstants.worldMinY), GameConstants.worldMaxY)
        )
    }

    func isSolid(at point: LevelGridPoint) -> Bool {
        if point.x < GameConstants.worldMinX || point.x > GameConstants.worldMaxX || point.y > GameConstants.worldMaxY {
            return true
        }

        if point.y < GameConstants.worldMinY {
            return false
        }

        switch tiles[point] {
        case .block, .lock, .turret, .homingTurret:
            return true
        default:
            return false
        }
    }
}

private struct LevelGridPoint: Hashable, Codable {
    var x: Int
    var y: Int
}

private struct LevelMovingPlatform: Identifiable, Equatable, Codable {
    let id: UUID
    var start: LevelGridPoint
    var end: LevelGridPoint
    var isLethal: Bool

    init(id: UUID = UUID(), start: LevelGridPoint, end: LevelGridPoint, isLethal: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.isLethal = isLethal
    }

    func touches(_ point: LevelGridPoint) -> Bool {
        start == point || end == point
    }

    var tint: Color {
        isLethal ? Color.redPop : Color.purplePop
    }
}

private enum LevelTileKind: Equatable, Codable {
    case block
    case kill
    case water
    case space
    case jumpPad(power: CGFloat)
    case ice
    case mud
    case conveyorLeft
    case conveyorRight
    case spring
    case checkpoint
    case heal
    case coin
    case key
    case lock
    case turret
    case homingTurret

    var symbolName: String {
        switch self {
        case .block:
            return "square.grid.3x3.fill"
        case .kill:
            return "xmark.octagon.fill"
        case .water:
            return "drop.fill"
        case .space:
            return "sparkles"
        case .jumpPad(_):
            return "arrow.up.circle.fill"
        case .ice:
            return "snowflake"
        case .mud:
            return "drop.triangle.fill"
        case .conveyorLeft:
            return "arrow.left.square.fill"
        case .conveyorRight:
            return "arrow.right.square.fill"
        case .spring:
            return "arrow.up.to.line.compact"
        case .checkpoint:
            return "flag.fill"
        case .heal:
            return "heart.fill"
        case .coin:
            return "circle.fill"
        case .key:
            return "key.fill"
        case .lock:
            return "lock.fill"
        case .turret:
            return "scope"
        case .homingTurret:
            return "location.north.fill"
        }
    }

    var fillColor: Color {
        switch self {
        case .block:
            return Color(red: 0.34, green: 0.37, blue: 0.39)
        case .kill:
            return Color(red: 0.55, green: 0.05, blue: 0.09)
        case .water:
            return Color(red: 0.08, green: 0.48, blue: 0.72)
        case .space:
            return Color(red: 0.09, green: 0.08, blue: 0.24)
        case .jumpPad(_):
            return Color(red: 0.1, green: 0.64, blue: 0.38)
        case .ice:
            return Color(red: 0.35, green: 0.78, blue: 0.92)
        case .mud:
            return Color(red: 0.42, green: 0.28, blue: 0.18)
        case .conveyorLeft, .conveyorRight:
            return Color(red: 0.22, green: 0.28, blue: 0.46)
        case .spring:
            return Color(red: 0.12, green: 0.62, blue: 0.45)
        case .checkpoint:
            return Color(red: 0.13, green: 0.44, blue: 0.56)
        case .heal:
            return Color(red: 0.62, green: 0.12, blue: 0.28)
        case .coin:
            return Color(red: 0.9, green: 0.68, blue: 0.12)
        case .key:
            return Color(red: 0.86, green: 0.62, blue: 0.16)
        case .lock:
            return Color(red: 0.21, green: 0.21, blue: 0.26)
        case .turret:
            return Color(red: 0.26, green: 0.23, blue: 0.34)
        case .homingTurret:
            return Color(red: 0.18, green: 0.25, blue: 0.36)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .block:
            return Color.white.opacity(0.68)
        case .kill:
            return Color(red: 1.0, green: 0.42, blue: 0.46)
        case .water:
            return Color(red: 0.72, green: 0.95, blue: 1.0)
        case .space:
            return Color(red: 0.92, green: 0.98, blue: 1.0)
        case .jumpPad(_):
            return Color(red: 0.74, green: 1.0, blue: 0.72)
        case .ice:
            return Color.white.opacity(0.9)
        case .mud:
            return Color(red: 1.0, green: 0.78, blue: 0.5)
        case .conveyorLeft, .conveyorRight:
            return Color(red: 0.72, green: 0.82, blue: 1.0)
        case .spring:
            return Color(red: 0.76, green: 1.0, blue: 0.8)
        case .checkpoint:
            return Color.sky
        case .heal:
            return Color(red: 1.0, green: 0.75, blue: 0.82)
        case .coin, .key:
            return Color(red: 1.0, green: 0.94, blue: 0.58)
        case .lock:
            return Color.white.opacity(0.82)
        case .turret:
            return Color(red: 1.0, green: 0.62, blue: 0.38)
        case .homingTurret:
            return Color(red: 0.52, green: 0.92, blue: 1.0)
        }
    }
}

private enum CreatorTool: String, CaseIterable, Identifiable, Equatable {
    case block
    case kill
    case water
    case space
    case jumpPad
    case ice
    case mud
    case conveyorLeft
    case conveyorRight
    case spring
    case checkpoint
    case heal
    case coin
    case key
    case lock
    case turret
    case homingTurret
    case moving
    case redMoving
    case enemy
    case start
    case end
    case delete
    case move

    var id: String { rawValue }

    static let defaultHotbarTools: [CreatorTool] = [
        .block, .kill, .water, .space, .jumpPad,
        .moving, .redMoving, .turret, .homingTurret, .enemy, .start, .end, .delete, .move
    ]

    static let blockLibraryTools: [CreatorTool] = [
        .block, .kill, .water, .space, .jumpPad,
        .ice, .mud, .conveyorLeft, .conveyorRight, .spring,
        .checkpoint, .heal, .coin, .key, .lock, .turret, .homingTurret, .redMoving
    ]

    var title: String {
        switch self {
        case .block:
            return "Block"
        case .kill:
            return "Kill"
        case .water:
            return "Water"
        case .space:
            return "Dream"
        case .jumpPad:
            return "Pad"
        case .ice:
            return "Ice"
        case .mud:
            return "Mud"
        case .conveyorLeft:
            return "Left Belt"
        case .conveyorRight:
            return "Right Belt"
        case .spring:
            return "Spring"
        case .checkpoint:
            return "Checkpoint"
        case .heal:
            return "Heal"
        case .coin:
            return "Coin"
        case .key:
            return "Key"
        case .lock:
            return "Lock"
        case .turret:
            return "Turret"
        case .homingTurret:
            return "Homing"
        case .moving:
            return "Moving"
        case .redMoving:
            return "Red Move"
        case .enemy:
            return "Enemy"
        case .start:
            return "Start"
        case .end:
            return "End"
        case .delete:
            return "Delete"
        case .move:
            return "Move"
        }
    }

    var hint: String {
        switch self {
        case .moving:
            return "Drag from a purple block to set its arrow path."
        case .redMoving:
            return "Drag from a red block to set its lethal path."
        case .kill:
            return "Kill blocks respawn the player on touch."
        case .space:
            return "Dream blocks glide fast and launch on jump."
        case .move:
            return "Drag the board to move the camera."
        case .jumpPad:
            return "Tune pad power, then place launch pads."
        case .ice:
            return "Ice keeps momentum and slides."
        case .mud:
            return "Mud slows player movement."
        case .conveyorLeft:
            return "Left belts push the player left."
        case .conveyorRight:
            return "Right belts push the player right."
        case .spring:
            return "Springs bounce the player upward."
        case .checkpoint:
            return "Checkpoints update respawn position."
        case .heal:
            return "Heal blocks restore one heart."
        case .coin:
            return "Coins can be collected in playtest."
        case .key:
            return "Keys unlock lock blocks."
        case .lock:
            return "Locks block the player until a key is held."
        case .turret:
            return "Shoots straight at the player."
        case .homingTurret:
            return "Shoots tracking projectiles."
        case .delete:
            return "Drag across tiles to remove them."
        default:
            return supportsDragPainting ? "Tap or drag across tiles to build." : "Tap a tile to place this."
        }
    }

    var supportsDragPainting: Bool {
        switch self {
        case .block, .kill, .water, .space, .jumpPad, .ice, .mud, .conveyorLeft, .conveyorRight, .spring, .checkpoint, .heal, .coin, .key, .lock, .turret, .homingTurret, .delete:
            return true
        case .moving, .redMoving, .enemy, .start, .end, .move:
            return false
        }
    }

    var isMovingPlatformTool: Bool {
        self == .moving || self == .redMoving
    }

    var symbolName: String {
        switch self {
        case .block:
            return "square.grid.3x3.fill"
        case .kill:
            return "xmark.octagon.fill"
        case .water:
            return "drop.fill"
        case .space:
            return "sparkles"
        case .jumpPad:
            return "arrow.up.circle.fill"
        case .ice:
            return "snowflake"
        case .mud:
            return "drop.triangle.fill"
        case .conveyorLeft:
            return "arrow.left.square.fill"
        case .conveyorRight:
            return "arrow.right.square.fill"
        case .spring:
            return "arrow.up.to.line.compact"
        case .checkpoint:
            return "flag.fill"
        case .heal:
            return "heart.fill"
        case .coin:
            return "circle.fill"
        case .key:
            return "key.fill"
        case .lock:
            return "lock.fill"
        case .turret:
            return "scope"
        case .homingTurret:
            return "location.north.fill"
        case .moving:
            return "arrow.left.and.right.square.fill"
        case .redMoving:
            return "xmark.diamond.fill"
        case .enemy:
            return "exclamationmark.triangle.fill"
        case .start:
            return "flag.fill"
        case .end:
            return "scope"
        case .delete:
            return "trash.fill"
        case .move:
            return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    var tint: Color {
        switch self {
        case .block:
            return Color(red: 0.78, green: 0.82, blue: 0.86)
        case .kill:
            return Color.redPop
        case .water:
            return Color(red: 0.34, green: 0.78, blue: 1.0)
        case .space:
            return Color(red: 0.58, green: 0.74, blue: 1.0)
        case .jumpPad:
            return Color.mintPop
        case .ice:
            return Color(red: 0.55, green: 0.9, blue: 1.0)
        case .mud:
            return Color(red: 0.95, green: 0.62, blue: 0.34)
        case .conveyorLeft, .conveyorRight:
            return Color(red: 0.62, green: 0.72, blue: 1.0)
        case .spring:
            return Color(red: 0.42, green: 1.0, blue: 0.72)
        case .checkpoint:
            return Color.sky
        case .heal:
            return Color(red: 1.0, green: 0.48, blue: 0.62)
        case .coin, .key:
            return Color.gold
        case .lock:
            return Color(red: 0.72, green: 0.74, blue: 0.82)
        case .turret:
            return Color(red: 1.0, green: 0.62, blue: 0.36)
        case .homingTurret:
            return Color.sky
        case .moving:
            return Color.purplePop
        case .redMoving:
            return Color.redPop
        case .enemy:
            return Color(red: 1.0, green: 0.44, blue: 0.5)
        case .start:
            return Color.mintPop
        case .end:
            return Color.gold
        case .delete:
            return Color(red: 1.0, green: 0.42, blue: 0.46)
        case .move:
            return Color(red: 0.72, green: 0.8, blue: 1.0)
        }
    }

    var featureText: String {
        switch self {
        case .block:
            return "Solid build block"
        case .kill:
            return "Touch to respawn"
        case .water:
            return "Float and swim"
        case .space:
            return "Dream drift block"
        case .jumpPad:
            return "Custom launch power"
        case .ice:
            return "Slippery movement"
        case .mud:
            return "Slows the player"
        case .conveyorLeft:
            return "Pushes left"
        case .conveyorRight:
            return "Pushes right"
        case .spring:
            return "Bounce pad"
        case .checkpoint:
            return "Respawn marker"
        case .heal:
            return "Restores health"
        case .coin:
            return "Collectible"
        case .key:
            return "Unlocks locks"
        case .lock:
            return "Requires key"
        case .turret:
            return "Straight shooter"
        case .homingTurret:
            return "Tracking shooter"
        case .moving:
            return "Purple path block"
        case .redMoving:
            return "Moving kill block"
        case .enemy:
            return "Walking hazard"
        case .start:
            return "Player spawn"
        case .end:
            return "Goal"
        case .delete:
            return "Erase tiles"
        case .move:
            return "Pan camera"
        }
    }
}

private struct LevelPlayState {
    var playerX: CGFloat
    var playerY: CGFloat
    var velocityX: CGFloat = 0
    var velocityY: CGFloat = 0
    var facing: CGFloat = 1
    var health = GameConstants.maxHealth
    var coins = 0
    var hasKey = false
    var collectedItems = Set<LevelGridPoint>()
    var checkpoint: LevelGridPoint?
    var isGrounded = false
    var attackCooldown: CGFloat = 0
    var attackFlash: CGFloat = 0
    var invulnerability: CGFloat = 0
    var wasInSpace = false
    var dreamDirectionX: CGFloat = 1
    var dreamDirectionY: CGFloat = 0
    var dreamExitGrace: CGFloat = 0
    var dreamBypass: CGFloat = 0
    var jumpBuffer: CGFloat = 0
    var groundGrace: CGFloat = 0
    var enemies: [LevelEnemyState]
    var projectiles: [LevelProjectileState] = []
    var turretCooldowns: [LevelGridPoint: CGFloat] = [:]
    var platforms: [LevelMovingPlatformState]
    var isComplete = false
    var statusText = "Reach the End"

    init(level: EditableLevel) {
        playerX = CGFloat(level.start.x) + 0.5
        playerY = CGFloat(level.start.y) + 0.38
        enemies = level.enemies
            .sorted { lhs, rhs in
                lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
            }
            .map { LevelEnemyState(point: $0) }
        platforms = level.movingPlatforms.map { LevelMovingPlatformState(platform: $0) }
    }
}

private struct LevelEnemyState: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var direction: CGFloat

    init(point: LevelGridPoint) {
        x = CGFloat(point.x) + 0.5
        y = CGFloat(point.y) + 0.45
        direction = point.x.isMultiple(of: 2) ? 1 : -1
    }
}

private struct LevelProjectileState: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var velocityX: CGFloat
    var velocityY: CGFloat
    var isHoming: Bool
    var life = GameConstants.projectileLife

    init(origin: CGPoint, target: CGPoint, isHoming: Bool) {
        self.isHoming = isHoming
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let length = max(hypot(dx, dy), 0.001)
        let speed = isHoming ? GameConstants.homingProjectileSpeed : GameConstants.turretProjectileSpeed
        let directionX = dx / length
        let directionY = dy / length
        x = origin.x + directionX * GameConstants.projectileSpawnOffset
        y = origin.y + directionY * GameConstants.projectileSpawnOffset
        velocityX = directionX * speed
        velocityY = directionY * speed
    }

    var collisionRect: CGRect {
        CGRect(
            x: x - GameConstants.projectileSize / 2,
            y: y - GameConstants.projectileSize / 2,
            width: GameConstants.projectileSize,
            height: GameConstants.projectileSize
        )
    }

    mutating func advance(toward target: CGPoint, deltaTime: CGFloat) {
        if isHoming {
            let dx = target.x - x
            let dy = target.y - y
            let length = max(hypot(dx, dy), 0.001)
            let targetX = dx / length * GameConstants.homingProjectileSpeed
            let targetY = dy / length * GameConstants.homingProjectileSpeed
            velocityX += (targetX - velocityX) * GameConstants.homingTurnRate
            velocityY += (targetY - velocityY) * GameConstants.homingTurnRate
        }

        x += velocityX * deltaTime
        y += velocityY * deltaTime
        life -= deltaTime
    }
}

private struct LevelMovingPlatformState: Identifiable {
    let id: UUID
    let isLethal: Bool
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    var progress: CGFloat = 0
    var direction: CGFloat = 1
    var previousX: CGFloat
    var previousY: CGFloat
    var x: CGFloat
    var y: CGFloat

    init(platform: LevelMovingPlatform) {
        id = platform.id
        isLethal = platform.isLethal
        startX = CGFloat(platform.start.x) + 0.5
        startY = CGFloat(platform.start.y) + 0.5
        endX = CGFloat(platform.end.x) + 0.5
        endY = CGFloat(platform.end.y) + 0.5
        previousX = startX
        previousY = startY
        x = startX
        y = startY
    }

    var deltaX: CGFloat { x - previousX }
    var deltaY: CGFloat { y - previousY }

    var collisionRect: CGRect {
        CGRect(
            x: x - GameConstants.platformWidth / 2,
            y: y - GameConstants.platformHeight / 2,
            width: GameConstants.platformWidth,
            height: GameConstants.platformHeight
        )
    }

    mutating func advance(deltaTime: CGFloat) {
        previousX = x
        previousY = y

        let deltaX = endX - startX
        let deltaY = endY - startY
        let distance = max(sqrt(deltaX * deltaX + deltaY * deltaY), 0.5)
        progress += direction * GameConstants.platformSpeed * deltaTime / distance
        if progress >= 1 {
            progress = 1
            direction = -1
        } else if progress <= 0 {
            progress = 0
            direction = 1
        }

        x = startX + (endX - startX) * progress
        y = startY + (endY - startY) * progress
    }
}

private struct GreenModeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background(
                Color.mintPop.opacity(configuration.isPressed ? 0.78 : 0.98),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: Color.mintPop.opacity(0.35), radius: 12, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
    }
}

private struct ToolButtonStyle: ButtonStyle {
    let tint: Color
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.black : tint)
            .background(
                isSelected
                    ? tint
                    : Color.white.opacity(configuration.isPressed ? 0.14 : 0.075),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.38) : tint.opacity(0.24), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private extension Color {
    static let mintPop = Color(red: 0.58, green: 0.9, blue: 0.67)
    static let sky = Color(red: 0.42, green: 0.76, blue: 0.96)
    static let gold = Color(red: 1.0, green: 0.76, blue: 0.28)
    static let redPop = Color(red: 1.0, green: 0.34, blue: 0.4)
    static let purplePop = Color(red: 0.78, green: 0.48, blue: 1.0)
    static let violetSoft = Color(red: 0.72, green: 0.44, blue: 0.96)
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
    }
}
