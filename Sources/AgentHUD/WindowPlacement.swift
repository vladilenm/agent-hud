import AppKit

enum HUDCorner: String, CaseIterable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft

    var id: Self { self }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }

    var title: String {
        switch self {
        case .topRight: return "Справа сверху"
        case .topLeft: return "Слева сверху"
        case .bottomRight: return "Справа снизу"
        case .bottomLeft: return "Слева снизу"
        }
    }

    func offset(of frame: CGRect, in bounds: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? frame.minX - bounds.minX : bounds.maxX - frame.maxX,
                y: isBottom ? frame.minY - bounds.minY : bounds.maxY - frame.maxY)
    }

    func frame(size: CGSize, in bounds: CGRect, offset: CGPoint) -> CGRect {
        let x = isLeft ? bounds.minX + offset.x : bounds.maxX - size.width - offset.x
        let y = isBottom ? bounds.minY + offset.y : bounds.maxY - size.height - offset.y
        return WindowPlacement.contain(CGRect(origin: CGPoint(x: x, y: y), size: size), in: bounds)
    }
}

enum WindowPlacement {
    static func contain(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        let x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
        let y = min(bounds.maxY - frame.height, max(frame.minY, bounds.minY))
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    static func statusButton(_ frame: CGRect, in screen: CGRect, above bounds: CGRect) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard !frame.isEmpty, screen.contains(center), center.y >= bounds.maxY else { return nil }
        return frame
    }

    static func menuFrame(size: CGSize, in bounds: CGRect, button: CGRect?, offset: CGPoint?) -> CGRect {
        let top = min(bounds.maxY, button?.minY ?? bounds.maxY)
        let space = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, top - bounds.minY))
        let fitted = CGSize(width: min(size.width, space.width), height: min(size.height, space.height))
        if let offset {
            let savedFrame = HUDCorner.topLeft.frame(size: fitted, in: bounds, offset: offset)
            return contain(savedFrame, in: space)
        }
        let x = (button?.midX ?? space.maxX) - fitted.width / 2
        return contain(CGRect(x: x, y: space.maxY - fitted.height, width: fitted.width, height: fitted.height), in: space)
    }
}

extension NSScreen {
    var placementID: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return localizedName
        }
        let id = number.uint32Value
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return String(id) }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var menuWindowBounds: CGRect {
        let visible = visibleFrame
        let menuBarBottom = frame.maxY - max(safeAreaInsets.top, NSStatusBar.system.thickness)
        let top = min(visible.maxY, menuBarBottom) - 4
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: max(0, top - visible.minY))
    }
}
