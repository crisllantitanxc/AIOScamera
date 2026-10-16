import SwiftUI
import AVFoundation

/// Visor de diretor: mostra no iPhone o quadro da a6700 com a lente escolhida.
final class ViewfinderCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "aioscamera.viewfinder")
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var outputAdded = false
    private var desiredTan: Double = 0.35
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var photoDone: ((UIImage?) -> Void)?

    @Published var device: AVCaptureDevice?
    @Published var denied = false
    /// tan(meio ângulo) do lado maior da imagem exibida, já com zoom.
    @Published var effectiveTan: Double = 0.6
    /// Proporção da imagem do iPhone (lado maior / menor).
    @Published var formatAspect: Double = 16.0 / 9.0
    @Published var lensName = ""

    func start(targetTan: Double) {
        desiredTan = targetTan
        CameraAuth.request { [weak self] ok in
            guard let self else { return }
            guard ok else { self.denied = true; return }
            self.denied = false
            self.queue.async {
                self.apply()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func update(targetTan: Double) {
        guard abs(targetTan - desiredTan) > 0.0005 else { return }
        desiredTan = targetTan
        queue.async { self.apply() }
    }

    private static func tanHalf(_ d: AVCaptureDevice) -> Double {
        tan(Double(d.activeFormat.videoFieldOfView) * Double.pi / 360)
    }

    private func apply() {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back).devices
        guard !found.isEmpty else { return }
        // Da lente mais fechada para a mais aberta.
        let list = found.sorted { $0.activeFormat.videoFieldOfView < $1.activeFormat.videoFieldOfView }
        let need = desiredTan
        let chosen = list.first(where: { Self.tanHalf($0) >= need }) ?? list[list.count - 1]

        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        if input?.device.uniqueID != chosen.uniqueID {
            if let old = input { session.removeInput(old) }
            if let ni = try? AVCaptureDeviceInput(device: chosen), session.canAddInput(ni) {
                session.addInput(ni)
                input = ni
            }
        }
        if !outputAdded, session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            outputAdded = true
        }
        session.commitConfiguration()

        guard let dev = input?.device else { return }
        let t = Self.tanHalf(dev)
        var z = max(1.0, t / need)
        z = min(z, Double(dev.maxAvailableVideoZoomFactor), Double(dev.activeFormat.videoMaxZoomFactor))
        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = CGFloat(z)
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            dev.unlockForConfiguration()
        } catch {}

        let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        let aspect = Double(max(dims.width, dims.height)) / Double(max(1, min(dims.width, dims.height)))
        let eff = t / z
        let name: String
        switch dev.deviceType {
        case .builtInUltraWideCamera: name = "Ultra-angular"
        case .builtInTelephotoCamera: name = "Tele"
        default: name = "Grande-angular"
        }
        let zoomText = z > 1.05 ? " · zoom \(fmt(z, 1))x" : ""
        DispatchQueue.main.async {
            if self.device?.uniqueID != dev.uniqueID {
                self.rotation = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
            }
            self.device = dev
            self.effectiveTan = eff
            self.formatAspect = aspect
            self.lensName = "iPhone \(name)" + zoomText
        }
    }

    func capture(_ done: @escaping (UIImage?) -> Void) {
        photoDone = done
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture
        queue.async {
            if let conn = self.photoOutput.connection(with: .video), let a = angle, conn.isVideoRotationAngleSupported(a) {
                conn.videoRotationAngle = a
            }
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.photoDone?(img)
            self.photoDone = nil
        }
    }
}

enum DeliveryAspect: String, CaseIterable, Identifiable {
    case r16x9, r239, r185, r4x5, r1x1, r9x16
    var id: String { rawValue }
    var name: String {
        switch self {
        case .r16x9: return "16:9"
        case .r239: return "2.39:1"
        case .r185: return "1.85:1"
        case .r4x5: return "4:5"
        case .r1x1: return "1:1"
        case .r9x16: return "9:16"
        }
    }
    /// largura / altura
    var ratio: Double {
        switch self {
        case .r16x9: return 16.0 / 9.0
        case .r239: return 2.39
        case .r185: return 1.85
        case .r4x5: return 0.8
        case .r1x1: return 1
        case .r9x16: return 9.0 / 16.0
        }
    }
}

/// Geometria do quadro: frações da imagem exibida e da máscara de entrega.
struct FrameGeometry {
    let frameW: Double  // fração da largura da imagem exibida
    let frameH: Double  // fração da altura da imagem exibida
    let maskW: Double   // fração da largura do quadro
    let maskH: Double   // fração da altura do quadro

    static func make(focal: Double, crop: Double, vertical: Bool, aspect: DeliveryAspect,
                     landscapeUI: Bool, effTan: Double, formatAspect: Double) -> FrameGeometry {
        let sensorLong = 23.5 / crop
        let sensorShort = sensorLong * 9.0 / 16.0
        // Quadro no mundo (horizontal x vertical), em tan do meio ângulo.
        let tw = (vertical ? sensorShort : sensorLong) / 2 / focal
        let th = (vertical ? sensorLong : sensorShort) / 2 / focal
        let shortTan = effTan / formatAspect
        let hTan = landscapeUI ? effTan : shortTan
        let vTan = landscapeUI ? shortTan : effTan
        let wWorld = tw, hWorld = th
        let r = aspect.ratio
        var mw = 1.0, mh = 1.0
        if wWorld / hWorld > r { mw = hWorld * r / wWorld } else { mh = (wWorld / r) / hWorld }
        return FrameGeometry(frameW: tw / hTan, frameH: th / vTan, maskW: mw, maskH: mh)
    }

    /// tan necessária no lado maior da imagem do iPhone para caber o quadro com folga.
    static func neededTan(focal: Double, crop: Double, vertical: Bool, landscapeUI: Bool, formatAspect: Double) -> Double {
        let sensorLong = 23.5 / crop
        let sensorShort = sensorLong * 9.0 / 16.0
        let tw = (vertical ? sensorShort : sensorLong) / 2 / focal
        let th = (vertical ? sensorLong : sensorShort) / 2 / focal
        let margin = 0.9
        let hFactor = landscapeUI ? 1.0 : 1.0 / formatAspect
        let vFactor = landscapeUI ? 1.0 / formatAspect : 1.0
        return max(tw / (margin * hFactor), th / (margin * vFactor))
    }
}

struct FrameOverlay: View {
    let geometry: FrameGeometry
    let imageAspect: Double
    let landscapeUI: Bool

    var body: some View {
        Canvas { ctx, size in
            let img = AVMakeRect(aspectRatio: landscapeUI ? CGSize(width: imageAspect, height: 1)
                                                          : CGSize(width: 1, height: imageAspect),
                                 insideRect: CGRect(origin: .zero, size: size))
            let fw = img.width * geometry.frameW
            let fh = img.height * geometry.frameH
            let frame = CGRect(x: img.midX - fw / 2, y: img.midY - fh / 2, width: fw, height: fh)
            let mw = fw * geometry.maskW, mh = fh * geometry.maskH
            let mask = CGRect(x: img.midX - mw / 2, y: img.midY - mh / 2, width: mw, height: mh)

            var shade = Path(CGRect(origin: .zero, size: size))
            shade.addRect(mask)
            ctx.fill(shade, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
            if geometry.maskW < 0.999 || geometry.maskH < 0.999 {
                ctx.stroke(Path(frame), with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            ctx.stroke(Path(mask), with: .color(Theme.accent), lineWidth: 2)

            var thirds = Path()
            for i in 1...2 {
                let x = mask.minX + mask.width * CGFloat(i) / 3
                let y = mask.minY + mask.height * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: x, y: mask.minY)); thirds.addLine(to: CGPoint(x: x, y: mask.maxY))
                thirds.move(to: CGPoint(x: mask.minX, y: y)); thirds.addLine(to: CGPoint(x: mask.maxX, y: y))
            }
            ctx.stroke(thirds, with: .color(.white.opacity(0.22)), lineWidth: 1)

            var cross = Path()
            cross.move(to: CGPoint(x: mask.midX - 10, y: mask.midY)); cross.addLine(to: CGPoint(x: mask.midX + 10, y: mask.midY))
            cross.move(to: CGPoint(x: mask.midX, y: mask.midY - 10)); cross.addLine(to: CGPoint(x: mask.midX, y: mask.midY + 10))
            ctx.stroke(cross, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

struct ViewfinderView: View {
    let active: Bool
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var scout: ScoutStore
    @StateObject private var cam = ViewfinderCamera()
    @State private var aspect: DeliveryAspect = .r16x9
    @State private var vertical = false
    @State private var crop120 = false
    @State private var landscapeUI = false
    @State private var banner: String?
    @State private var saving = false

    static let lenses: [Double] = [10, 11, 15, 16, 18, 20, 24, 30, 35, 50, 56, 70, 85, 135]

    private var crop: Double { crop120 ? 1.58 : 1.0 }

    private var neededTan: Double {
        FrameGeometry.neededTan(focal: settings.focal, crop: crop, vertical: vertical,
                                landscapeUI: landscapeUI, formatAspect: cam.formatAspect)
    }

    private var geometry: FrameGeometry {
        FrameGeometry.make(focal: settings.focal, crop: crop, vertical: vertical, aspect: aspect,
                           landscapeUI: landscapeUI, effTan: cam.effectiveTan, formatAspect: cam.formatAspect)
    }

    var body: some View {
        GeometryReader { screen in
            let isLandscape = screen.size.width > screen.size.height
            Group {
                if isLandscape {
                    ZStack(alignment: .trailing) {
                        viewport
                        landscapeControls
                    }
                } else {
                    VStack(spacing: 0) {
                        viewport.frame(height: screen.size.height * 0.58)
                        controls
                    }
                }
            }
            .onAppear { landscapeUI = isLandscape }
            .onChange(of: isLandscape) { _, l in landscapeUI = l }
        }
        .background(Color.black)
        .banner($banner)
        .onAppear { if active { cam.start(targetTan: neededTan) } }
        .onDisappear { cam.stop() }
        .onChange(of: active) { _, on in if on { cam.start(targetTan: neededTan) } else { cam.stop() } }
        .onChange(of: neededTan) { _, t in cam.update(targetTan: t) }
    }

    private var viewport: some View {
        ZStack {
            CameraPreview(session: cam.session, device: cam.device, gravity: .resizeAspect)
            FrameOverlay(geometry: geometry, imageAspect: cam.formatAspect, landscapeUI: landscapeUI)
            VStack(spacing: 6) {
                Text("\(Int(settings.focal))mm na a6700 · equiv. FF \(Int((settings.focal * 1.5 * crop).rounded()))mm · \(aspect.name)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                if let hint = hintText {
                    Text(hint)
                        .font(.caption2)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accent.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                Spacer()
                Text(cam.lensName).font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            .padding(10)
            if cam.denied { PermissionMessage(text: "O visor precisa da câmera.") }
        }
    }

    private var hintText: String? {
        if geometry.frameW > 1.01 || geometry.frameH > 1.01 {
            return "Lente mais aberta que o iPhone consegue mostrar"
        }
        if vertical && landscapeUI { return "Câmera na vertical: segure o iPhone em pé" }
        if !vertical && !landscapeUI && aspect.ratio > 1 { return "Deite o iPhone para ver o quadro grande" }
        return nil
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Lente (mm)")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.lenses, id: \.self) { l in
                            Button("\(Int(l))") { settings.focal = l }
                                .buttonStyle(.bordered)
                                .tint(settings.focal == l ? Theme.accent : .gray)
                        }
                    }
                }
                Stepper("Outra: \(Int(settings.focal)) mm", value: $settings.focal, in: 8...600, step: 1)
                SectionLabel("Proporção de entrega")
                Picker("Proporção", selection: $aspect) {
                    ForEach(DeliveryAspect.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Câmera girada (vertical)", isOn: $vertical)
                Toggle("4K 120p (crop 1.58x)", isOn: $crop120)
                Button {
                    captureFrame()
                } label: {
                    Label(saving ? "Salvando…" : "Salvar quadro no scout", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saving || cam.device == nil)
            }
            .padding(16)
        }
    }

    private var landscapeControls: some View {
        VStack(spacing: 12) {
            Button { stepLens(-1) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int(settings.focal))").font(.headline.monospacedDigit())
            Button { stepLens(1) } label: { Image(systemName: "plus.magnifyingglass") }
            Menu {
                Picker("Proporção", selection: $aspect) {
                    ForEach(DeliveryAspect.allCases) { Text($0.name).tag($0) }
                }
            } label: { Image(systemName: "aspectratio") }
            Button { captureFrame() } label: {
                Image(systemName: "circle.inset.filled").font(.largeTitle)
            }
            .disabled(saving)
        }
        .font(.title3)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.trailing, 12)
    }

    private func stepLens(_ dir: Int) {
        let l = Self.lenses
        if dir > 0 {
            settings.focal = l.first(where: { $0 > settings.focal }) ?? settings.focal
        } else {
            settings.focal = l.last(where: { $0 < settings.focal }) ?? settings.focal
        }
    }

    private func captureFrame() {
        saving = true
        let g = geometry
        let focal = settings.focal
        let aspectName = aspect.name
        let isVertical = vertical
        let landscape = landscapeUI
        cam.capture { image in
            saving = false
            guard let image else { banner = "Não deu para tirar a foto"; return }
            let cropped = Self.cropImage(image, geometry: g, landscapeUI: landscape)
            let lines = [
                "Lente \(Int(focal))mm (equiv. FF \(Int((focal * 1.5 * crop).rounded()))mm)",
                "Proporção \(aspectName)" + (isVertical ? ", câmera na vertical" : "")
            ]
            let name = scout.addEntry(title: "Quadro do visor", lines: lines, image: cropped)
            banner = "Quadro salvo em \(name)"
        }
    }

    /// Recorta a foto no quadro da a6700 (com a máscara de proporção).
    static func cropImage(_ image: UIImage, geometry g: FrameGeometry, landscapeUI: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cg = normalized.cgImage else { return image }
        let w = Double(cg.width), h = Double(cg.height)
        // A foto sai na orientação em que o iPhone estava, igual à prévia.
        let photoLandscape = w >= h
        var fw = g.frameW, fh = g.frameH
        if photoLandscape != landscapeUI { swap(&fw, &fh) }
        let cw = w * fw * g.maskW
        let ch = h * fh * g.maskH
        let rect = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isEmpty, let c = cg.cropping(to: rect) else { return normalized }
        return UIImage(cgImage: c)
    }
}
