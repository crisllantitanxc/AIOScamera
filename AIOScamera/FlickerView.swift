import SwiftUI
import AVFoundation

/// Detecta flicker pelas faixas que a luz pulsante cria no sensor (rolling shutter).
/// A câmera roda a 27 fps, que não é múltiplo de 100/120 Hz, então as faixas andam
/// de um quadro para o outro e a diferença entre quadros revela o flicker.
final class FlickerCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct SweepResult: Identifiable {
        let id = UUID()
        let shutter: Double
        let index: Double
    }

    static let sweepShutters: [Double] = [1.0 / 48, 1.0 / 50, 1.0 / 60, 1.0 / 100, 1.0 / 120, 1.0 / 125, 1.0 / 250]

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "aioscamera.flicker")
    private let videoQueue = DispatchQueue(label: "aioscamera.flicker.video")
    private var configured = false
    private let lock = NSLock()
    private var prev: [Float] = []
    private var samples: [Double] = []
    private var lastMean: Double = 0
    private var uiTimer: Timer?

    @Published var device: AVCaptureDevice?
    @Published var denied = false
    @Published var index: Double = 0
    @Published var brightness: Double = 0
    @Published var shutter: Double = 1.0 / 50
    @Published var results: [SweepResult] = []
    @Published var sweeping = false
    @Published var progress: Double = 0

    func start() {
        CameraAuth.request { [weak self] ok in
            guard let self else { return }
            guard ok else { self.denied = true; return }
            self.denied = false
            self.queue.async {
                if !self.configured { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.setShutter(self.shutter) }
            }
            self.uiTimer?.invalidate()
            self.uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.index = self.medianIndex()
                self.lock.lock(); let b = self.lastMean; self.lock.unlock()
                self.brightness = b
            }
        }
    }

    func stop() {
        uiTimer?.invalidate()
        uiTimer = nil
        queue.async {
            if let dev = self.device, (try? dev.lockForConfiguration()) != nil {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.unlockForConfiguration()
            }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private static func pickFPS(_ f: AVCaptureDevice.Format) -> Int32 {
        for c in [27, 25, 30] {
            if f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(c) && $0.maxFrameRate >= Double(c) }) {
                return Int32(c)
            }
        }
        return 30
    }

    private func configure() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        do {
            try dev.lockForConfiguration()
            let fps = Self.pickFPS(dev.activeFormat)
            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
            dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
            dev.unlockForConfiguration()
        } catch {}
        configured = true
        DispatchQueue.main.async { self.device = dev }
    }

    /// Simula o obturador da câmera no sensor do iPhone, mantendo o brilho.
    func setShutter(_ t: Double) {
        shutter = t
        guard let dev = device else { return }
        queue.async {
            do {
                try dev.lockForConfiguration()
                let f = dev.activeFormat
                let minD = CMTimeGetSeconds(f.minExposureDuration)
                let maxD = min(CMTimeGetSeconds(f.maxExposureDuration), CMTimeGetSeconds(dev.activeVideoMaxFrameDuration))
                let d = min(max(t, minD), maxD)
                let curISO = Double(dev.iso)
                let curD = CMTimeGetSeconds(dev.exposureDuration)
                var iso = curD > 0 ? curISO * curD / d : curISO
                iso = min(max(iso, Double(f.minISO)), Double(f.maxISO))
                dev.setExposureModeCustom(duration: CMTime(seconds: d, preferredTimescale: 1_000_000),
                                          iso: Float(iso), completionHandler: nil)
                dev.unlockForConfiguration()
            } catch {}
            self.resetSamples()
        }
    }

    func resetSamples() {
        lock.lock()
        samples.removeAll()
        prev = []
        lock.unlock()
    }

    func medianIndex() -> Double {
        lock.lock()
        let s = samples.sorted()
        lock.unlock()
        guard !s.isEmpty else { return 0 }
        return s[s.count / 2]
    }

    func sweep() {
        guard !sweeping else { return }
        sweeping = true
        results = []
        progress = 0
        let list = Self.sweepShutters
        Task { @MainActor in
            for (i, t) in list.enumerated() {
                self.setShutter(t)
                try? await Task.sleep(nanoseconds: 600_000_000)
                self.resetSamples()
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                self.results.append(SweepResult(shutter: t, index: self.medianIndex()))
                self.progress = Double(i + 1) / Double(list.count)
            }
            if let best = self.results.min(by: { $0.index < $1.index }) { self.setShutter(best.shutter) }
            self.sweeping = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Média de cada linha (as faixas de flicker são horizontais no buffer do sensor).
        var profile: [Float] = []
        profile.reserveCapacity(h / 3 + 1)
        let x0 = w / 5, x1 = w * 4 / 5
        var total: Float = 0
        var y = 0
        while y < h {
            let row = ptr + y * bpr
            var s = 0, n = 0
            var x = x0
            while x < x1 { s += Int(row[x]); n += 1; x += 6 }
            let v = Float(s) / Float(max(n, 1))
            profile.append(v)
            total += v
            y += 3
        }
        guard !profile.isEmpty else { return }
        let mean = total / Float(profile.count)

        lock.lock()
        let p = prev
        prev = profile
        lastMean = Double(mean)
        lock.unlock()
        guard p.count == profile.count, mean > 12, mean < 240 else { return }

        // Razão quadro atual / anterior, sem tendência linear (movimento e brilho geral).
        let n = profile.count
        var r = [Double](repeating: 0, count: n)
        for i in 0..<n { r[i] = Double(profile[i] / max(p[i], 1)) - 1 }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for i in 0..<n {
            let xi = Double(i)
            sx += xi; sy += r[i]; sxx += xi * xi; sxy += xi * r[i]
        }
        let dn = Double(n)
        let slope = (dn * sxy - sx * sy) / max(dn * sxx - sx * sx, 1e-9)
        let icpt = (sy - slope * sx) / dn
        var sq = 0.0
        for i in 0..<n {
            let v = r[i] - (icpt + slope * Double(i))
            sq += v * v
        }
        let rms = sqrt(sq / dn) * 100

        lock.lock()
        samples.append(rms)
        if samples.count > 40 { samples.removeFirst(samples.count - 40) }
        lock.unlock()
    }
}

enum FlickerLevel {
    case none, light, strong
    init(_ index: Double) {
        if index < 0.6 { self = .none } else if index < 2.0 { self = .light } else { self = .strong }
    }
    var text: String {
        switch self {
        case .none: return "Sem flicker"
        case .light: return "Flicker leve"
        case .strong: return "Flicker forte"
        }
    }
    var color: Color {
        switch self {
        case .none: return Theme.good
        case .light: return Theme.warn
        case .strong: return Theme.bad
        }
    }
}

struct FlickerView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var scout: ScoutStore
    @StateObject private var cam = FlickerCamera()
    @State private var banner: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ZStack {
                    CameraPreview(session: cam.session, device: cam.device)
                    if cam.denied { PermissionMessage(text: "O detector precisa da câmera.") }
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                let level = FlickerLevel(cam.index)
                Card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("Agora em \(ExposureMath.shutterText(cam.shutter))")
                            BigNumber(text: level.text, size: 30, color: level.color)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            SectionLabel("Índice")
                            BigNumber(text: fmt(cam.index, 1) + "%", size: 26)
                        }
                    }
                    if cam.brightness > 0 && cam.brightness < 25 {
                        Text("Imagem escura demais. Chegue mais perto da luz ou de uma parede iluminada.")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    } else if cam.brightness > 235 {
                        Text("Imagem estourada. Aponte para uma área menos clara.")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    }
                    Text("Aponte para uma parede ou papel iluminado pela luz e segure o iPhone parado.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Card {
                    SectionLabel("Testar obturador")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FlickerCamera.sweepShutters, id: \.self) { t in
                                Button(ExposureMath.shutterText(t)) { cam.setShutter(t) }
                                    .buttonStyle(.bordered)
                                    .tint(abs(cam.shutter - t) < 1e-6 ? Theme.accent : .gray)
                                    .disabled(cam.sweeping)
                            }
                        }
                    }
                    Button {
                        cam.sweep()
                    } label: {
                        Label(cam.sweeping ? "Testando… \(Int(cam.progress * 100))%" : "Testar todos automaticamente",
                              systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cam.sweeping || cam.device == nil)

                    if !cam.results.isEmpty {
                        let best = cam.results.min(by: { $0.index < $1.index })
                        ForEach(cam.results) { r in
                            HStack {
                                Text(ExposureMath.shutterText(r.shutter)).monospacedDigit().frame(width: 56, alignment: .leading)
                                GeometryReader { g in
                                    let lv = FlickerLevel(r.index)
                                    Capsule().fill(lv.color)
                                        .frame(width: max(6, g.size.width * CGFloat(min(r.index, 5) / 5)))
                                }
                                .frame(height: 10)
                                Text(fmt(r.index, 1) + "%").font(.caption).monospacedDigit().frame(width: 48, alignment: .trailing)
                                if r.id == best?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good) }
                            }
                        }
                    }
                }

                Card {
                    SectionLabel("Rede elétrica de 60 Hz (Brasil)")
                    Text(recommendation).font(.callout)
                    Text("Luz de 60 Hz pisca 120 vezes por segundo. Obturadores que são múltiplos de 1/120 (1/120, 1/60, 1/40, 1/30) não mostram faixas.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Button {
                    let lines = cam.results.isEmpty
                        ? ["\(level.text) em \(ExposureMath.shutterText(cam.shutter)) (índice \(fmt(cam.index, 1))%)"]
                        : cam.results.map { "\(ExposureMath.shutterText($0.shutter)): \(FlickerLevel($0.index).text) (\(fmt($0.index, 1))%)" }
                    let name = scout.addEntry(title: "Flicker", lines: lines + [recommendation])
                    banner = "Salvo em \(name)"
                } label: {
                    Label("Salvar no scout", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
        }
        .navigationTitle("Flicker")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black)
        .banner($banner)
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }

    private var recommendation: String {
        switch settings.fps {
        case ..<26: return "Gravando \(Int(settings.fps))p: use 1/60 em vez de 1/50 perto de LED e fluorescente. O movimento fica um pouco mais nítido, mas sem pulsar."
        case ..<31: return "Gravando 30p: 1/60 é o 180° perfeito e não pisca."
        case ..<61: return "Gravando \(Int(settings.fps))p: use 1/120 se a câmera permitir. Se não, 1/60. Evite 1/125 e 1/100 com luz artificial."
        default: return "Gravando \(Int(settings.fps))p: use 1/120 ou 1/240 com luz artificial."
        }
    }
}
