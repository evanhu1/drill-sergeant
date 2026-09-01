import AppKit

struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchRect: CGRect
    let hasPhysicalNotch: Bool

    /// Returns one continuous panel covering the notch and extending below it.
    func panelFrame(panelHeight: CGFloat) -> CGRect {
        CGRect(
            x: notchRect.minX,
            y: notchRect.minY - panelHeight,
            width: notchRect.width,
            height: notchRect.height + panelHeight
        )
    }

    static func detect(screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            return NotchGeometry(
                screenFrame: frame,
                notchRect: CGRect(
                    x: leftArea.maxX,
                    y: frame.maxY - topInset,
                    width: rightArea.minX - leftArea.maxX,
                    height: topInset
                ),
                hasPhysicalNotch: true
            )
        }

        return synthetic(screenFrame: frame)
    }

    static func synthetic(screenFrame frame: CGRect) -> NotchGeometry {
        let width: CGFloat = 200
        let height: CGFloat = 32
        return NotchGeometry(
            screenFrame: frame,
            notchRect: CGRect(
                x: frame.midX - width / 2,
                y: frame.maxY - height,
                width: width,
                height: height
            ),
            hasPhysicalNotch: false
        )
    }
}
