import SwiftUI
import ARKit
import SceneKit
import CoreLocation

/// Realidade aumentada: desenha o sol e o caminho dele no céu, ancorados no norte verdadeiro.
final class SunARModel: NSObject, ObservableObject, ARSessionDelegate {
    weak var view: ARSCNView?
    private let root = SCNNode()
    private var lastUpdate: TimeInterval = 0
    private var running = false

    @Published var hint = "Aponte a câmera para o céu"
    @Published var tracking = "Calibrando bússola…"
    var sunAz: Double = 0
    var sunEl: Double = -90

    static var supported: Bool { ARWorldTrackingConfiguration.isSupported }

    func attach(_ v: ARSCNView) {
        view = v
        v.session.delegate = self
        root.removeFromParentNode()
        v.scene.rootNode.addChildNode(root)
        v.automaticallyUpdatesLighting = false
        if running { run() }
    }

    func run() {
        running = true
        guard Self.supported, let v = view else { return }
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravityAndHeading
        v.session.run(c, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        running = false
        view?.session.pause()
    }

    // MARK: Cena

    static func vector(az: Double, el: Double, dist: Float) -> SCNVector3 {
        let a = az * Double.pi / 180, e = el * Double.pi / 180
        return SCNVector3(Float(sin(a) * cos(e)) * dist, Float(sin(e)) * dist, Float(-cos(a) * cos(e)) * dist)
    }

    private func material(_ c: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = c
        m.emission.contents = c
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        return m
    }

    private func label(_ s: String, at pos: SCNVector3, scale: Float, color: UIColor) -> SCNNode {
        let t = SCNText(string: s, extrusionDepth: 0)
        t.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        t.flatness = 0.3
        t.firstMaterial = material(color)
        let n = SCNNode(geometry: t)
        let (minB, maxB) = n.boundingBox
        n.pivot = SCNMatrix4MakeTranslation((maxB.x + minB.x) / 2, (maxB.y + minB.y) / 2, 0)
        n.scale = SCNVector3(scale, scale, scale)
        let holder = SCNNode()
        holder.position = pos
        holder.addChildNode(n)
        let b = SCNBillboardConstraint()
        b.freeAxes = .all
        holder.constraints = [b]
        return holder
    }

    func rebuild(date: Date, lat: Double, lon: Double) {
        root.childNodes.forEach { $0.removeFromParentNode() }
        let dist: Float = 40
        let cur = SunMath.position(date: date, lat: lat, lon: lon)
        sunAz = cur.azimuth
        sunEl = cur.elevation

        let cal = Calendar.current
        for p in SunMath.path(day: date, lat: lat, lon: lon, stepMinutes: 10) where p.position.elevation > -6 {
            let golden = p.position.elevation < 6
            let dot = SCNNode(geometry: SCNSphere(radius: golden ? 0.3 : 0.22))
            dot.geometry?.firstMaterial = material(golden ? UIColor.orange : UIColor.white.withAlphaComponent(0.7))
            dot.position = Self.vector(az: p.position.azimuth, el: p.position.elevation, dist: dist)
            root.addChildNode(dot)
            if cal.component(.minute, from: p.date) == 0 {
                let h = cal.component(.hour, from: p.date)
                let pos = Self.vector(az: p.position.azimuth, el: p.position.elevation + 2.5, dist: dist)
                root.addChildNode(label("\(h)h", at: pos, scale: 0.06, color: .white))
            }
        }

        let sun = SCNNode(geometry: SCNSphere(radius: 1.6))
        sun.geometry?.firstMaterial = material(UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1))
        sun.position = Self.vector(az: cur.azimuth, el: cur.elevation, dist: dist)
        root.addChildNode(sun)
        root.addChildNode(label(hm(date), at: Self.vector(az: cur.azimuth, el: cur.elevation - 4.5, dist: dist),
                                scale: 0.08, color: UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)))

        for (name, az) in [("N", 0.0), ("L", 90.0), ("S", 180.0), ("O", 270.0)] {
            root.addChildNode(label(name, at: Self.vector(az: az, el: 0, dist: dist), scale: 0.1, color: .cyan))
        }
        // Linha do horizonte
        var a = 0.0
        while a < 360 {
            let n = SCNNode(geometry: SCNSphere(radius: 0.1))
            n.geometry?.firstMaterial = material(UIColor.cyan.withAlphaComponent(0.5))
            n.position = Self.vector(az: a, el: 0, dist: dist)
            root.addChildNode(n)
            a += 5
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.camera.transform
        root.simdPosition = simd_make_float3(t.columns.3)
        guard frame.timestamp - lastUpdate > 0.25 else { return }
        lastUpdate = frame.timestamp

        let f = -simd_make_float3(t.columns.2)
        var camAz = atan2(Double(f.x), Double(-f.z)) * 180 / Double.pi
        if camAz < 0 { camAz += 360 }
        let camEl = asin(Double(max(-1, min(1, f.y)))) * 180 / Double.pi
        var d = sunAz - camAz
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        let de = sunEl - camEl

        let text: String
        if abs(d) < 10 && abs(de) < 14 {
            text = sunEl < -0.8 ? "O sol está aí, abaixo do horizonte" : "Sol no centro da tela"
        } else {
            var parts: [String] = []
            if abs(d) >= 10 { parts.append("vire \(Int(abs(d)))° à \(d > 0 ? "direita" : "esquerda")") }
            if abs(de) >= 14 { parts.append("\(de > 0 ? "suba" : "desça") \(Int(abs(de)))°") }
            text = "Sol: " + parts.joined(separator: " e ")
        }
        if text != hint { hint = text }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let s: String
        switch camera.trackingState {
        case .normal: s = ""
        case .notAvailable: s = "AR indisponível"
        case .limited(let reason):
            switch reason {
            case .initializing, .relocalizing: s = "Calibrando… mexa o iPhone devagar"
            case .excessiveMotion: s = "Mexa mais devagar"
            case .insufficientFeatures: s = "Pouca textura na imagem, mas a direção vale"
            @unknown default: s = "Rastreamento limitado"
            }
        }
        tracking = s
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        tracking = "Erro no AR: \(error.localizedDescription)"
    }
}

struct SunARContainer: UIViewRepresentable {
    let model: SunARModel
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.autoenablesDefaultLighting = false
        model.attach(v)
        return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
    }
}

/// Mapa do céu visto de cima: norte em cima, horizonte na borda, zênite no centro.
struct SunPathDiagram: View {
    let path: [SunPathPoint]
    let current: SunPosition?

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 22
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func point(_ p: SunPosition) -> CGPoint {
                let rr = r * CGFloat(max(0, 90 - p.elevation) / 90)
                let a = p.azimuth * Double.pi / 180
                return CGPoint(x: c.x + rr * CGFloat(sin(a)), y: c.y - rr * CGFloat(cos(a)))
            }
            for el in [0.0, 30, 60] {
                let rr = r * CGFloat((90 - el) / 90)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(.white.opacity(el == 0 ? 0.45 : 0.15)), lineWidth: 1)
            }
            for (name, az) in [("N", 0.0), ("L", 90.0), ("S", 180.0), ("O", 270.0)] {
                let a = az * Double.pi / 180
                let pt = CGPoint(x: c.x + (r + 12) * CGFloat(sin(a)), y: c.y - (r + 12) * CGFloat(cos(a)))
                ctx.draw(Text(name).font(.caption.bold()).foregroundColor(.cyan), at: pt)
            }
            var prev: SunPathPoint?
            for p in path {
                if let q = prev, q.position.elevation > 0 || p.position.elevation > 0 {
                    var seg = Path()
                    seg.move(to: point(q.position))
                    seg.addLine(to: point(p.position))
                    let golden = p.position.elevation < 6
                    ctx.stroke(seg, with: .color(golden ? Theme.accent : .white.opacity(0.75)), lineWidth: golden ? 3 : 2)
                }
                if p.position.elevation > 0, Calendar.current.component(.minute, from: p.date) == 0 {
                    let h = Calendar.current.component(.hour, from: p.date)
                    if h % 2 == 0 {
                        ctx.draw(Text("\(h)h").font(.caption2).foregroundColor(.white.opacity(0.7)),
                                 at: CGPoint(x: point(p.position).x, y: point(p.position).y - 10))
                    }
                }
                prev = p
            }
            if let cur = current, cur.elevation > -1 {
                let pt = point(cur)
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 9, y: pt.y - 9, width: 18, height: 18)),
                         with: .color(Color(red: 1, green: 0.85, blue: 0.3)))
            }
        }
    }
}

struct SunView: View {
    let active: Bool
    @EnvironmentObject var scout: ScoutStore
    @ObservedObject private var loc = LocationManager.shared
    @StateObject private var ar = SunARModel()
    @State private var mode = 0
    @State private var date = Date()
    @State private var builtCoord: CLLocation?
    @State private var builtDate = Date.distantPast
    @State private var banner: String?

    private var coord: CLLocationCoordinate2D? { loc.location?.coordinate }
    private var arOn: Bool { active && mode == 0 && SunARModel.supported }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Modo", selection: $mode) {
                Text("Câmera AR").tag(0)
                Text("Mapa do dia").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ZStack {
                if mode == 0 {
                    if SunARModel.supported {
                        SunARContainer(model: ar)
                        VStack {
                            if !ar.tracking.isEmpty {
                                pill(ar.tracking, color: Color.black.opacity(0.55))
                            }
                            Spacer()
                            pill(ar.hint, color: Theme.accent.opacity(0.9), dark: true)
                        }
                        .padding(10)
                    } else {
                        Text("Este iPhone não suporta AR. Use o Mapa do dia.").foregroundStyle(.secondary)
                    }
                } else if let c = coord {
                    SunPathDiagram(path: SunMath.path(day: date, lat: c.latitude, lon: c.longitude, stepMinutes: 10),
                                   current: SunMath.position(date: date, lat: c.latitude, lon: c.longitude))
                        .padding(8)
                }
                if coord == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(loc.denied ? "Ative a localização em Ajustes > AIOScamera para calcular o sol."
                                        : "Buscando sua localização…")
                            .font(.subheadline).multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(height: 340)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipped()

            ScrollView {
                VStack(spacing: 12) {
                    if let c = coord { infoCards(c) }
                }
                .padding(16)
            }
        }
        .background(Color.black)
        .banner($banner)
        .onAppear {
            loc.start()
            rebuildIfNeeded(force: true)
            if arOn { ar.run() }
        }
        .onDisappear { ar.pause() }
        .onChange(of: arOn) { _, on in if on { ar.run() } else { ar.pause() } }
        .onChange(of: date) { _, _ in rebuildIfNeeded(force: true) }
        .onChange(of: loc.location) { _, _ in rebuildIfNeeded(force: false) }
    }

    private func pill(_ s: String, color: Color, dark: Bool = false) -> some View {
        Text(s)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(dark ? Color.black : Color.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(color, in: Capsule())
    }

    private func rebuildIfNeeded(force: Bool) {
        guard let l = loc.location else { return }
        if !force, let b = builtCoord, b.distance(from: l) < 500 { return }
        builtCoord = l
        builtDate = date
        ar.rebuild(date: date, lat: l.coordinate.latitude, lon: l.coordinate.longitude)
    }

    @ViewBuilder
    private func infoCards(_ c: CLLocationCoordinate2D) -> some View {
        let pos = SunMath.position(date: date, lat: c.latitude, lon: c.longitude)
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Direção do sol")
                    BigNumber(text: "\(Int(pos.azimuth.rounded()))° \(SunMath.cardinal(pos.azimuth))", size: 34)
                    Text("vem do \(SunMath.cardinalName(pos.azimuth))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    SectionLabel("Altura")
                    BigNumber(text: "\(Int(pos.elevation.rounded()))°", size: 34)
                }
            }
            Text(SunMath.lightTip(pos.elevation)).font(.footnote).foregroundStyle(.secondary)
        }
        Card {
            SectionLabel("Planejar")
            DatePicker("Data e hora", selection: $date)
            HStack {
                Button("Agora") { date = Date() }.buttonStyle(.bordered)
                Spacer()
                Text("No local, abra o app Bússola do iPhone para conferir a direção.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        Card {
            SectionLabel("Luz do dia")
            ForEach(SunMath.windows(day: date, lat: c.latitude, lon: c.longitude)) { w in
                HStack {
                    Text(w.name)
                        .foregroundStyle(w.name.contains("Golden") ? Theme.accent : (w.name.contains("Blue") ? Color.cyan : Color.primary))
                    Spacer()
                    Text(w.text).monospacedDigit()
                }
                .font(.callout)
            }
        }
        Button {
            let windows = SunMath.windows(day: date, lat: c.latitude, lon: c.longitude)
            var lines = ["Às \(hm(date)): sol a \(Int(pos.azimuth.rounded()))° (\(SunMath.cardinal(pos.azimuth))), \(Int(pos.elevation.rounded()))° de altura"]
            lines += windows.map { "\($0.name): \($0.text)" }
            let name = scout.addEntry(title: "Sol", lines: lines, includeSun: false)
            banner = "Salvo em \(name)"
        } label: {
            Label("Salvar horários no scout", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
