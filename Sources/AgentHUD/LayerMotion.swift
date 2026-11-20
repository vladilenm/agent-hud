import AppKit
import QuartzCore
import SwiftUI

/// Бесконечные анимации через Core Animation. Их считает системный рендер-сервер,
/// а не SwiftUI в нашем процессе (SwiftUI тикал бы 120 раз в секунду и ел CPU).
enum LayerMotionKind: Hashable {
    case none
    /// Покачивание, пока агент работает: бесконечное, фаза непрерывна (см. MotionClock).
    case sway(amplitude: CGFloat, duration: Double, delay: Double)
    /// Подпрыгивание, когда агент ждёт тебя: короткий всплеск внимания, потом покой.
    case bounce(amplitude: CGFloat, duration: Double, delay: Double)
    /// Пульс бейджа «!»: несколько вспышек, потом бейдж просто горит.
    case pulse
}

/// Общие часы анимаций и счётчик перевешиваний (для --uitest).
enum MotionClock {
    /// Точка отсчёта фазы покачивания: анимация, повешенная заново, продолжает с той же фазы — без рывка.
    static let epoch = CACurrentMediaTime()
    /// Сколько раз анимация вешалась на слой. Растёт только при смене вида движения
    /// (или если AppKit сам снял анимацию), а не при каждой раскладке.
    static var installs = 0
    /// Сколько повторов делает всплеск внимания (подпрыгивание, пульс).
    static let bounceRepeats: Float = 4      // ≈ 2,6 с при длительности 0,32 с туда и обратно
    static let pulseRepeats: Float = 3       // ≈ 5 с
}

struct LayerMotion<Content: View>: NSViewRepresentable {
    let kind: LayerMotionKind
    let content: Content

    init(_ kind: LayerMotionKind, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    func makeNSView(context: Context) -> MotionHostView<Content> {
        MotionHostView(rootView: content)
    }

    func updateNSView(_ v: MotionHostView<Content>, context: Context) {
        v.host.rootView = content
        v.apply(kind)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MotionHostView<Content>, context: Context) -> CGSize? {
        nsView.host.fittingSize
    }
}

final class MotionHostView<Content: View>: NSView {
    let host: NSHostingView<Content>
    private var current: LayerMotionKind = .none

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        host.frame = bounds
        // Раньше анимация снималась и вешалась заново на КАЖДОЙ раскладке. Раскладка идёт на каждом кадре
        // любой анимации окна (сессия появилась, окошко открылось) — иконки дёргались и «залипали».
        // Теперь вешаем заново, только если AppKit сам снял анимацию со слоя.
        ensureInstalled()
    }

    /// Клики проходят насквозь к SwiftUI-кнопке снаружи.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ kind: LayerMotionKind) {
        guard kind != current else { ensureInstalled(); return }
        current = kind
        install()
    }

    private func ensureInstalled() {
        guard current != .none, let layer = host.layer, layer.animation(forKey: "motion") == nil else { return }
        // Всплеск внимания, который уже отыграл, остаётся на слое (isRemovedOnCompletion = false),
        // так что сюда попадаем, только если слой действительно потерял анимацию.
        install()
    }

    private func install() {
        guard let layer = host.layer else { return }
        layer.removeAnimation(forKey: "motion")
        switch current {
        case .none:
            return
        case .sway(let amp, let dur, let delay):
            let a = loop("transform.translation.y", to: amp, dur: dur, timing: .easeInEaseOut)
            // Фаза от общих часов: перевешивание не сбрасывает покачивание в ноль.
            a.beginTime = layer.convertTime(MotionClock.epoch + delay, from: nil)
            layer.add(a, forKey: "motion")
        case .bounce(let amp, let dur, let delay):
            let g = CAAnimationGroup()
            g.animations = [
                loop("transform.translation.y", to: amp, dur: dur, timing: .easeOut),
                loop("transform.scale.y", to: 0.05, dur: dur, timing: .easeOut),
            ]
            g.duration = dur
            g.autoreverses = true
            g.repeatCount = MotionClock.bounceRepeats
            g.beginTime = layer.convertTime(CACurrentMediaTime() + delay * 0.3, from: nil)
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            layer.add(g, forKey: "motion")
        case .pulse:
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.55
            a.duration = 0.8
            a.autoreverses = true
            a.repeatCount = MotionClock.pulseRepeats
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "motion")
        }
        MotionClock.installs += 1
    }

    /// Аддитивная анимация туда-обратно: поверх исходного значения, модель слоя не трогаем.
    private func loop(_ path: String, to: CGFloat, dur: Double, timing: CAMediaTimingFunctionName) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: path)
        a.isAdditive = true
        a.fromValue = 0
        a.toValue = to
        a.duration = dur
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.isRemovedOnCompletion = false
        return a
    }
}
