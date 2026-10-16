import SwiftUI
import AVFoundation

/// Lê ao vivo o balanço de branco e a exposição que o sensor do iPhone calcula.
final class MeterCamera: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "aioscamera.meter")
    private var configured = false
    private var timer: Timer?

    @Published var device: AVCaptureDevice?
    @Published var denied = false
    @Published var frozen = false
    @Published var spotPoint: CGPoint?
    @Published var phoneISO: Double = 0
    @Published var phoneShutter: Double = 0
    @Published var phoneAperture: Double = 1.8
    @Published var sceneEV: Double = 0
    @Published var kelvin: Double = 5600
    @Published var tint: Double = 0
    @Published var hasReading = false

    func start() {
        CameraAuth.request { [weak self] ok in
            guard let self else { return }
            guard ok else { self.denied = true; return }
            self.denied = false
            self.queue.async {
                if !self.configured { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.startTimer() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: dev),
           session.canAddInput(input) {
            session.addInput(input)
            do {
                try dev.lockForConfiguration()
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                dev.unlockForConfiguration()
            } catch {}
            DispatchQueue.main.async { self.device = dev }
        }
        session.commitConfiguration()
        configured = true
    }

    /// Toque na imagem = fotômetro spot naquele ponto. nil volta pra média central.
    func setSpot(devicePoint: CGPoint?, layerPoint: CGPoint?) {
        spotPoint = layerPoint
        guard let dev = device else { return }
        queue.async {
            do {
                try dev.lockForConfiguration()
                if dev.isExposurePointOfInterestSupported {
                    dev.exposurePointOfInterest = devicePoint ?? CGPoint(x: 0.5, y: 0.5)
                }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    private func sample() {
        guard !frozen, let dev = device else { return }
        let iso = Double(dev.iso)
        let dur = CMTimeGetSeconds(dev.exposureDuration)
        let ap = Double(dev.lensAperture)
        guard iso > 0, dur > 0, ap > 0 else { return }

        // EV da cena = EV dos ajustes do iPhone + quanto ele está fora do alvo de exposição.
        let ev = ExposureMath.ev100(aperture: ap, shutter: dur, iso: iso) + Double(dev.exposureTargetOffset)

        var g = dev.deviceWhiteBalanceGains
        let maxG = dev.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), maxG)
        g.greenGain = min(max(g.greenGain, 1), maxG)
        g.blueGain = min(max(g.blueGain, 1), maxG)
        let tt = dev.temperatureAndTintValues(for: g)

        let a = hasReading ? 0.25 : 1.0
        phoneISO = iso
        phoneShutter = dur
        phoneAperture = ap
        sceneEV += (ev - sceneEV) * a
        kelvin += (Double(tt.temperature) - kelvin) * a
        tint += (Double(tt.tint) - tint) * a
        hasReading = true
    }
}

struct MeterView: View {
    let active: Bool
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var scout: ScoutStore
    @StateObject private var cam = MeterCamera()
    @State private var banner: String?

    private var kelvin: Double { cam.kelvin + settings.kelvinOffset }
    private var tint: Double { (settings.invertTint ? -cam.tint : cam.tint) + settings.tintOffset }
    private var ev: Double { cam.sceneEV + settings.evOffset }
    private var plan: ExposurePlan {
        ExposureMath.plan(sceneEV: ev, profile: settings.profile, aperture: settings.aperture,
                          shutter: settings.cameraShutter, comp: settings.exposureComp)
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(height: 290)
                .clipped()
            ScrollView {
                VStack(spacing: 12) {
                    colorCard
                    exposureCard
                    setupCard
                    Button {
                        save()
                    } label: {
                        Label("Salvar medição no scout", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!cam.hasReading)
                    Text("Aponte para um papel branco ou cartão cinza iluminado só pela luz que você quer medir. Toque na imagem para medir a exposição de um ponto (spot).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .background(Color.black)
        .banner($banner)
        .onAppear { if active { cam.start() } }
        .onDisappear { cam.stop(); storeReading() }
        .onChange(of: active) { _, on in
            if on { cam.start() } else { cam.stop(); storeReading() }
        }
    }

    private var preview: some View {
        ZStack {
            CameraPreview(session: cam.session, device: cam.device, onTap: { p, dp in
                cam.setSpot(devicePoint: dp, layerPoint: p)
            })
            .overlay {
                GeometryReader { geo in
                    let p = cam.spotPoint ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    ZStack {
                        Circle()
                            .stroke(cam.spotPoint == nil ? Color.white.opacity(0.7) : Theme.accent, lineWidth: 2)
                            .frame(width: cam.spotPoint == nil ? 120 : 56, height: cam.spotPoint == nil ? 120 : 56)
                        Image(systemName: "plus").foregroundStyle(.white.opacity(0.8))
                    }
                    .position(p)
                    .allowsHitTesting(false)
                }
            }
            VStack {
                HStack {
                    Text(cam.spotPoint == nil ? "MÉDIA CENTRAL" : "SPOT")
                        .font(.caption2.weight(.bold)).tracking(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    if cam.spotPoint != nil {
                        Button("Voltar à média") { cam.setSpot(devicePoint: nil, layerPoint: nil) }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button {
                        cam.frozen.toggle()
                        if cam.frozen { storeReading() }
                    } label: {
                        Label(cam.frozen ? "Travado" : "Travar", systemImage: cam.frozen ? "lock.fill" : "lock.open")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(cam.frozen ? Theme.accent : Color.gray.opacity(0.5))
                }
                Spacer()
            }
            .padding(12)
            if cam.denied {
                PermissionMessage(text: "O AIOScamera precisa da câmera para medir a luz.")
            }
        }
    }

    private var colorCard: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Temperatura de cor")
                    BigNumber(text: "\(Int((kelvin / 50).rounded() * 50).formatted()) K", size: 44)
                    Text(ColorMath.sourceName(kelvin)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    SectionLabel("Tint")
                    BigNumber(text: (tint >= 0 ? "+" : "") + fmt(tint, 0), size: 28)
                    Text(ColorMath.tintDescription(tint)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Image(systemName: "camera")
                Text("Na a6700: **\(ColorMath.sonyKelvin(kelvin)) K** · G-M **\(ColorMath.sonyGM(tint))**")
                Spacer()
            }
            .font(.callout)
            Text("Em S-Log3 use WB fixo em Kelvin, nunca AWB.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var exposureCard: some View {
        let p = plan
        let color: Color = {
            switch p.status {
            case .ok: return Theme.good
            case .needsND: return Theme.accent
            case .noisy: return Theme.warn
            case .tooDark: return Theme.bad
            }
        }()
        return Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("ISO na a6700")
                    BigNumber(text: Int(p.iso).formatted(), size: 44, color: color)
                    Text("base do \(settings.profile.name): \(Int(settings.profile.baseISO))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    SectionLabel("EV da cena")
                    BigNumber(text: fmt(ev, 1), size: 28)
                    if cam.phoneShutter > 0 {
                        Text("iPhone: ISO \(Int(cam.phoneISO)) · \(ExposureMath.shutterText(cam.phoneShutter))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let nd = p.ndFilter {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "circle.lefthalf.filled")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use **\(nd)**").font(.callout)
                        if let alt = p.altAperture {
                            Text("Sem ND: feche para \(ExposureMath.apertureText(alt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(p.note).font(.footnote).foregroundStyle(color)
        }
    }

    private var setupCard: some View {
        Card {
            SectionLabel("Seu setup")
            HStack {
                Menu {
                    Picker("Perfil", selection: $settings.profile) {
                        ForEach(CameraProfile.allCases) { Text($0.name).tag($0) }
                    }
                } label: { chip(settings.profile.name) }
                Menu {
                    Picker("FPS", selection: $settings.fps) {
                        ForEach(AppSettings.fpsOptions, id: \.self) { Text("\(Int($0))p").tag($0) }
                    }
                } label: { chip("\(Int(settings.fps))p") }
                Menu {
                    Picker("Diafragma", selection: $settings.aperture) {
                        ForEach(ExposureMath.apertures, id: \.self) { Text(ExposureMath.apertureText($0)).tag($0) }
                    }
                } label: { chip(ExposureMath.apertureText(settings.aperture)) }
                Spacer()
            }
            Text("Obturador \(ExposureMath.shutterText(settings.cameraShutter)) (\(Int(settings.shutterAngle))°)"
                 + (settings.exposureComp != 0 ? " · compensação \(settings.exposureComp > 0 ? "+" : "")\(fmt(settings.exposureComp, 1)) EV" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    private func storeReading() {
        guard cam.hasReading else { return }
        LastReading.shared.kelvin = kelvin
        LastReading.shared.tint = tint
        LastReading.shared.ev = ev
    }

    private func save() {
        storeReading()
        let p = plan
        var lines = [
            "Luz: \(Int(kelvin.rounded())) K (\(ColorMath.sourceName(kelvin))), tint \(fmt(tint, 0))",
            "a6700: WB \(ColorMath.sonyKelvin(kelvin)) K, G-M \(ColorMath.sonyGM(tint))",
            "EV \(fmt(ev, 1)) · \(settings.profile.name) \(Int(settings.fps))p \(ExposureMath.shutterText(settings.cameraShutter)) \(ExposureMath.apertureText(settings.aperture)) → ISO \(Int(p.iso))"
        ]
        if let nd = p.ndFilter { lines.append("Filtro: \(nd)") }
        let name = scout.addEntry(title: cam.spotPoint == nil ? "Medição" : "Medição spot", lines: lines)
        banner = "Salvo em \(name)"
    }
}
