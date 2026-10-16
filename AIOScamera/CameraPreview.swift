import SwiftUI
import AVFoundation

enum CameraAuth {
    static func request(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default:
            done(false)
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private(set) var deviceID: String?
    var onTap: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    func attach(_ device: AVCaptureDevice?) {
        guard let device, device.uniqueID != deviceID else { return }
        deviceID = device.uniqueID
        let c = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        coordinator = c
        observation = c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyRotation() }
        }
    }

    func applyRotation() {
        guard let c = coordinator, let conn = previewLayer.connection else { return }
        let angle = c.videoRotationAngleForHorizonLevelPreview
        if conn.isVideoRotationAngleSupported(angle), conn.videoRotationAngle != angle {
            conn.videoRotationAngle = angle
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyRotation()
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        let dp = previewLayer.captureDevicePointConverted(fromLayerPoint: p)
        onTap?(p, dp)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = gravity
        v.onTap = onTap
        v.attach(device)
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        v.onTap = onTap
        if v.previewLayer.videoGravity != gravity { v.previewLayer.videoGravity = gravity }
        v.attach(device)
        v.applyRotation()
    }
}
