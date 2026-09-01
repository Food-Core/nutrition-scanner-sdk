//
//  Viewfinder overlay: corner brackets, animated scan line + "Analyzing
//  label…" while scanning, status text, and a flash toggle. Add it over your
//  camera preview layer, pinned to the same bounds. Every element is
//  configurable; `isHidden = true` (or showsBrackets/showsFlashButton = false)
//  hides pieces or the whole thing.
//

import AVFoundation
import UIKit

public final class ScannerOverlayView: UIView {

    /// Corner-bracket framing box.
    public var showsBrackets = true { didSet { setNeedsLayout() } }

    /// Flash button (shown by default; set false to hide).
    public var showsFlashButton = true { didSet { flashButton.isHidden = !showsFlashButton } }

    public var analyzingText = "Analyzing label…"

    /// Called on flash taps; the default implementation also toggles the
    /// device torch — override by assigning your own closure.
    public var onToggleFlash: ((Bool) -> Void)?

    private let bracketLayer = CAShapeLayer()
    private let scanLine = UIView()
    private let statusLabel = UILabel()
    private let flashButton = UIButton(type: .system)
    private var analyzing = false
    private var flashOn = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isUserInteractionEnabled = true
        backgroundColor = .clear

        bracketLayer.strokeColor = UIColor.white.withAlphaComponent(0.92).cgColor
        bracketLayer.fillColor = UIColor.clear.cgColor
        bracketLayer.lineWidth = 3
        bracketLayer.lineCap = .round
        layer.addSublayer(bracketLayer)

        scanLine.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        scanLine.layer.shadowColor = UIColor.white.cgColor
        scanLine.layer.shadowOpacity = 0.7
        scanLine.layer.shadowRadius = 6
        scanLine.isHidden = true
        addSubview(scanLine)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.layer.shadowColor = UIColor.black.cgColor
        statusLabel.layer.shadowOpacity = 0.85
        statusLabel.layer.shadowRadius = 4
        addSubview(statusLabel)

        flashButton.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
        flashButton.tintColor = .white
        flashButton.backgroundColor = .black
        flashButton.layer.cornerRadius = 21
        flashButton.accessibilityLabel = "Toggle flash"
        flashButton.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
        addSubview(flashButton)
    }

    /// Update the guidance line ("Hold steady…").
    public func setStatus(_ message: String) {
        if !analyzing { statusLabel.text = message }
    }

    /// Toggle the analyzing state: animated scan line + analyzingText.
    public func setAnalyzing(_ on: Bool) {
        analyzing = on
        scanLine.isHidden = !on
        if on {
            statusLabel.text = analyzingText
            let animation = CABasicAnimation(keyPath: "position.y")
            animation.fromValue = bounds.height * 0.14
            animation.toValue = bounds.height * 0.86
            animation.duration = 2.2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scanLine.layer.add(animation, forKey: "nls-scan")
        } else {
            scanLine.layer.removeAnimation(forKey: "nls-scan")
        }
    }

    @objc private func flashTapped() {
        flashOn.toggle()
        flashButton.tintColor = flashOn
            ? UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
            : .white
        if let onToggleFlash {
            onToggleFlash(flashOn)
        } else {
            ScannerOverlayView.setTorch(on: flashOn)
        }
    }

    /// Convenience: toggles the back camera's torch directly.
    public static func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let h = bounds.height

        scanLine.frame = CGRect(x: w * 0.14, y: h * 0.14, width: w * 0.72, height: 2)
        statusLabel.frame = CGRect(x: 16, y: h - h * 0.04 - 44, width: w - 32, height: 44)
        flashButton.frame = CGRect(x: w - 52, y: 10, width: 42, height: 42)
        flashButton.isHidden = !showsFlashButton

        guard showsBrackets else {
            bracketLayer.path = nil
            return
        }
        let insetX = w * 0.12
        let insetY = h * 0.12
        let arm = min(w, h) * 0.09
        let path = UIBezierPath()
        func corner(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
            path.move(to: CGPoint(x: x + arm * dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + arm * dy))
        }
        corner(insetX, insetY, 1, 1)
        corner(w - insetX, insetY, -1, 1)
        corner(insetX, h - insetY, 1, -1)
        corner(w - insetX, h - insetY, -1, -1)
        bracketLayer.path = path.cgPath
    }
}
