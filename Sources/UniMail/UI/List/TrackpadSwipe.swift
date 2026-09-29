import AppKit
import SwiftUI

// Свайп строки двумя пальцами по трекпаду (без нажатия).
//
// Трекпад присылает жест как серию событий scrollWheel с фазами began → changed… → ended (+ инерция
// с momentumPhase). Один локальный монитор на всё приложение (TrackpadSwipeCenter) смотрит на начало жеста:
// если указатель над строкой списка, жест «решается» по первым пикселям: преимущественно горизонтальный
// захватывается (события больше не доходят до ScrollView), вертикальный целиком отдаётся списку.
// Пока направление не решено, события проходят в список — вертикальная прокрутка не страдает.

/// Невидимый вид под строкой: регистрирует область строки в TrackpadSwipeCenter.
@MainActor
struct TrackpadSwipeCatcher: NSViewRepresentable {
    var isEnabled: Bool = true
    /// Смещение пальцев по горизонтали с начала жеста (вправо — положительное).
    var onChanged: (CGFloat) -> Void
    /// Конец жеста: итоговое смещение и скорость (pt/s). При отмене жеста — (0, 0).
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeNSView(context: Context) -> TrackpadSwipeView {
        let view = TrackpadSwipeView()
        configure(view)
        return view
    }

    func updateNSView(_ view: TrackpadSwipeView, context: Context) {
        configure(view)
    }

    static func dismantleNSView(_ view: TrackpadSwipeView, coordinator: ()) {
        TrackpadSwipeCenter.shared.unregister(view)
        view.onChanged = nil
        view.onEnded = nil
    }

    private func configure(_ view: TrackpadSwipeView) {
        view.isEnabled = isEnabled
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

final class TrackpadSwipeView: NSView {
    var isEnabled = true
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat, CGFloat) -> Void)?

    /// Клики и наведение проходят насквозь к строке.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TrackpadSwipeCenter.shared.register(self)
        } else {
            TrackpadSwipeCenter.shared.unregister(self)
        }
    }

    /// Точка окна внутри видимой части строки.
    func containsVisible(windowPoint: NSPoint) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        let local = convert(windowPoint, from: nil)
        return bounds.contains(local) && visibleRect.contains(local)
    }
}

/// Общий монитор scrollWheel. Установлен, пока в окнах есть хотя бы одна строка со свайпом.
@MainActor
final class TrackpadSwipeCenter {
    static let shared = TrackpadSwipeCenter()

    private enum Stage { case idle, deciding, horizontal, passthrough }

    private let views = NSHashTable<TrackpadSwipeView>.weakObjects()
    private var monitor: Any?
    private var state: Stage = .idle
    private weak var target: TrackpadSwipeView?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var translation: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastMoveTime: TimeInterval = 0
    /// Часть жеста уже ушла в ScrollView — отдаём ему и конец, чтобы он не остался «в жесте».
    private var passedBegin = false
    /// Инерция после захваченного жеста не должна прокручивать список.
    private var swallowMomentum = false

    /// Сколько пикселей нужно, чтобы решить направление.
    private let decisionDistance: CGFloat = 4

    private init() {}

    func register(_ view: TrackpadSwipeView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func unregister(_ view: TrackpadSwipeView) {
        views.remove(view)
        if views.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            reset()
            swallowMomentum = false
        }
    }

    // MARK: События

    private func handle(_ event: NSEvent) -> NSEvent? {
        if !event.momentumPhase.isEmpty {
            guard swallowMomentum else { return event }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                swallowMomentum = false
            }
            return nil
        }

        let phase = event.phase
        // Колесо мыши (без фаз) и «палец коснулся» не трогаем.
        if phase.isEmpty || phase.contains(.mayBegin) { return event }

        if phase.contains(.began) {
            reset()
            swallowMomentum = false
            guard let view = views.allObjects.first(where: {
                $0.isEnabled && $0.window === event.window && $0.containsVisible(windowPoint: event.locationInWindow)
            }) else {
                state = .passthrough
                return event
            }
            target = view
            state = .deciding
            lastMoveTime = event.timestamp
            return decide(event)
        }

        if phase.contains(.changed) || phase.contains(.stationary) {
            switch state {
            case .deciding:
                return decide(event)
            case .horizontal:
                feed(event)
                return nil
            case .idle, .passthrough:
                return event
            }
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            guard state == .horizontal else {
                reset()
                return event
            }
            feed(event)
            let cancelled = phase.contains(.cancelled)
            // Пальцы остановились перед отрывом — это не бросок.
            let finalVelocity = event.timestamp - lastMoveTime > 0.08 ? 0 : velocity
            target?.onEnded?(cancelled ? 0 : translation, cancelled ? 0 : finalVelocity)
            swallowMomentum = true
            let pass = passedBegin
            reset()
            return pass ? event : nil
        }
        return event
    }

    /// Накопление первых пикселей жеста и выбор направления.
    private func decide(_ event: NSEvent) -> NSEvent? {
        let delta = fingerDelta(event)
        accumulatedX += delta.x
        accumulatedY += delta.y
        let absX = abs(accumulatedX)
        let absY = abs(accumulatedY)
        guard max(absX, absY) >= decisionDistance else {
            passedBegin = true
            return event
        }
        if absX > absY {
            state = .horizontal
            translation = accumulatedX
            velocity = 0
            lastMoveTime = event.timestamp
            target?.onChanged?(translation)
            return nil
        }
        state = .passthrough
        target = nil
        return event
    }

    private func feed(_ event: NSEvent) {
        let dx = fingerDelta(event).x
        guard dx != 0 else { return }
        translation += dx
        let dt = event.timestamp - lastMoveTime
        if dt > 0.0005 {
            let instant = dx / CGFloat(dt)
            velocity = velocity * 0.35 + instant * 0.65
        }
        lastMoveTime = event.timestamp
        target?.onChanged?(translation)
    }

    /// Смещение пальцев: с учётом точности дельт и «естественной» прокрутки.
    private func fingerDelta(_ event: NSEvent) -> (x: CGFloat, y: CGFloat) {
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        var dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale
        // При «естественной» прокрутке (isDirectionInvertedFromDevice) содержимое следует за пальцами
        // и знак дельты совпадает с их движением; при обычной — противоположен.
        if !event.isDirectionInvertedFromDevice { dx = -dx }
        return (dx, dy)
    }

    private func reset() {
        state = .idle
        target = nil
        accumulatedX = 0
        accumulatedY = 0
        translation = 0
        velocity = 0
        passedBegin = false
    }
}
