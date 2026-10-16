import Foundation
import SwiftUI
import CoreLocation

// MARK: - Perfis da Sony a6700

enum CameraProfile: String, CaseIterable, Identifiable {
    case slog3, scinetone, rec709
    var id: String { rawValue }

    var name: String {
        switch self {
        case .slog3: return "S-Log3"
        case .scinetone: return "S-Cinetone"
        case .rec709: return "Padrão (709)"
        }
    }

    /// ISO base (mínimo recomendado) na a6700.
    var baseISO: Double {
        switch self {
        case .slog3: return 800
        case .scinetone, .rec709: return 100
        }
    }

    /// A partir daqui o ruído começa a aparecer.
    var noiseISO: Double {
        switch self {
        case .slog3: return 6400
        case .scinetone, .rec709: return 3200
        }
    }
}

// MARK: - Ajustes salvos

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var profile: CameraProfile { didSet { UserDefaults.standard.set(profile.rawValue, forKey: "profile") } }
    @Published var fps: Double { didSet { UserDefaults.standard.set(fps, forKey: "fps") } }
    @Published var shutterAngle: Double { didSet { UserDefaults.standard.set(shutterAngle, forKey: "shutterAngle") } }
    @Published var aperture: Double { didSet { UserDefaults.standard.set(aperture, forKey: "aperture") } }
    @Published var focal: Double { didSet { UserDefaults.standard.set(focal, forKey: "focal") } }
    @Published var exposureComp: Double { didSet { UserDefaults.standard.set(exposureComp, forKey: "exposureComp") } }
    @Published var kelvinOffset: Double { didSet { UserDefaults.standard.set(kelvinOffset, forKey: "kelvinOffset") } }
    @Published var tintOffset: Double { didSet { UserDefaults.standard.set(tintOffset, forKey: "tintOffset") } }
    @Published var invertTint: Bool { didSet { UserDefaults.standard.set(invertTint, forKey: "invertTint") } }
    @Published var evOffset: Double { didSet { UserDefaults.standard.set(evOffset, forKey: "evOffset") } }

    init() {
        let d = UserDefaults.standard
        profile = CameraProfile(rawValue: d.string(forKey: "profile") ?? "") ?? .slog3
        fps = (d.object(forKey: "fps") as? Double) ?? 24
        shutterAngle = (d.object(forKey: "shutterAngle") as? Double) ?? 180
        aperture = (d.object(forKey: "aperture") as? Double) ?? 2.8
        focal = (d.object(forKey: "focal") as? Double) ?? 35
        exposureComp = (d.object(forKey: "exposureComp") as? Double) ?? 0
        kelvinOffset = (d.object(forKey: "kelvinOffset") as? Double) ?? 0
        tintOffset = (d.object(forKey: "tintOffset") as? Double) ?? 0
        invertTint = d.bool(forKey: "invertTint")
        evOffset = (d.object(forKey: "evOffset") as? Double) ?? 0
    }

    static let fpsOptions: [Double] = [24, 25, 30, 50, 60, 100, 120]

    var exactShutter: Double { shutterAngle / 360.0 / fps }
    /// Velocidade de obturador disponível na câmera mais próxima do ângulo escolhido.
    var cameraShutter: Double { ExposureMath.nearestShutter(exactShutter) }

    func resetCalibration() {
        kelvinOffset = 0; tintOffset = 0; invertTint = false; evOffset = 0
    }
}

/// Última leitura do Medidor, para outras abas reaproveitarem.
final class LastReading: ObservableObject {
    static let shared = LastReading()
    @Published var kelvin: Double?
    @Published var tint: Double?
    @Published var ev: Double?
}

// MARK: - Exposição

struct ExposurePlan {
    enum Status { case ok, needsND, noisy, tooDark }
    var iso: Double
    var isoExact: Double
    var ndStops: Double
    var ndFilter: String?
    var altAperture: Double?
    var status: Status
    var note: String
}

enum ExposureMath {
    static let isoStops: [Double] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600,
                                     2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000]
    static let apertures: [Double] = [1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8,
                                      9, 10, 11, 13, 14, 16, 18, 20, 22]
    static let shutterDenoms: [Double] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500,
                                          400, 320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25]
    static let ndFilters: [(name: String, stops: Double)] = [
        ("ND2", 1), ("ND4", 2), ("ND8", 3), ("ND16", 4), ("ND32", 5), ("ND64", 6),
        ("ND128", 7), ("ND256", 8), ("ND400", 8.6), ("ND1000", 10)
    ]
    static let maxVideoISO: Double = 32000

    static func nearest(_ v: Double, in list: [Double]) -> Double {
        guard v > 0, var best = list.first else { return list.first ?? v }
        var bestD = Double.infinity
        for x in list {
            let dd = abs(log2(x / v))
            if dd < bestD { bestD = dd; best = x }
        }
        return best
    }

    static func nearestShutter(_ t: Double) -> Double { 1.0 / nearest(1.0 / t, in: shutterDenoms) }

    static func ev100(aperture: Double, shutter: Double, iso: Double) -> Double {
        log2(aperture * aperture / shutter) - log2(iso / 100.0)
    }

    static func requiredISO(ev100: Double, aperture: Double, shutter: Double) -> Double {
        100.0 * aperture * aperture / shutter / pow(2.0, ev100)
    }

    static func shutterText(_ t: Double) -> String {
        if t >= 0.5 { return fmt(t, 1) + "\"" }
        return "1/\(Int((1.0 / t).rounded()))"
    }

    static func apertureText(_ n: Double) -> String {
        if n >= 10 || abs(n - n.rounded()) < 0.01 { return "f/\(Int(n.rounded()))" }
        return "f/" + fmt(n, 1)
    }

    static func plan(sceneEV: Double, profile: CameraProfile, aperture: Double, shutter: Double, comp: Double) -> ExposurePlan {
        let ev = sceneEV - comp
        let need = requiredISO(ev100: ev, aperture: aperture, shutter: shutter)
        let base = profile.baseISO
        let allowed = isoStops.filter { $0 >= base && $0 <= maxVideoISO }

        if need < base / pow(2, 1.0 / 6.0) {
            let stops = log2(base / need)
            let nd = ndFilters.first(where: { $0.stops >= stops - 0.17 }) ?? ndFilters[ndFilters.count - 1]
            let isoAfter = nearest(need * pow(2.0, nd.stops), in: allowed)
            let altN = aperture * pow(2.0, stops / 2.0)
            let alt: Double? = altN <= 22.5 ? nearest(altN, in: apertures) : nil
            let note: String
            if stops > nd.stops + 0.3 {
                note = "Luz demais até para o \(nd.name). Empilhe NDs ou feche o diafragma."
            } else {
                note = "Precisa de \(fmt(stops, 1)) stops de ND (no VND, \(fmt(stops, 1)) stops)."
            }
            return ExposurePlan(iso: isoAfter, isoExact: need, ndStops: stops, ndFilter: nd.name,
                                altAperture: alt, status: .needsND, note: note)
        }

        let iso = nearest(need, in: allowed)
        if need > maxVideoISO * 1.12 {
            let missing = log2(need / maxVideoISO)
            return ExposurePlan(iso: maxVideoISO, isoExact: need, ndStops: 0, ndFilter: nil, altAperture: nil,
                                status: .tooDark,
                                note: "Faltam \(fmt(missing, 1)) stops de luz. Abra o diafragma, ilumine ou baixe o fps.")
        }
        if need > profile.noiseISO * 1.12 {
            return ExposurePlan(iso: iso, isoExact: need, ndStops: 0, ndFilter: nil, altAperture: nil, status: .noisy,
                                note: "ISO alto para \(profile.name): vai aparecer ruído. Abra o diafragma ou adicione luz.")
        }
        return ExposurePlan(iso: iso, isoExact: need, ndStops: 0, ndFilter: nil, altAperture: nil, status: .ok,
                            note: "Exposição certa sem ND.")
    }
}

// MARK: - Cor

struct LightSource: Identifiable {
    let id = UUID()
    let name: String
    let kelvin: Double
    let gm: String
}

enum ColorMath {
    static let sources: [LightSource] = [
        LightSource(name: "Vela / fogueira", kelvin: 1900, gm: "0"),
        LightSource(name: "Lâmpada incandescente", kelvin: 2700, gm: "0"),
        LightSource(name: "LED quente doméstico", kelvin: 3000, gm: "M1"),
        LightSource(name: "Tungstênio de estúdio", kelvin: 3200, gm: "0"),
        LightSource(name: "Nascer / pôr do sol", kelvin: 3500, gm: "0"),
        LightSource(name: "Fluorescente branca fria", kelvin: 4100, gm: "M2"),
        LightSource(name: "LED branco neutro", kelvin: 4500, gm: "M1"),
        LightSource(name: "Flash", kelvin: 5500, gm: "0"),
        LightSource(name: "Sol do meio-dia", kelvin: 5600, gm: "0"),
        LightSource(name: "Céu nublado", kelvin: 6500, gm: "0"),
        LightSource(name: "Sombra aberta", kelvin: 7500, gm: "0"),
        LightSource(name: "Céu azul / blue hour", kelvin: 9000, gm: "0")
    ]

    static func mired(_ k: Double) -> Double { 1_000_000.0 / k }

    static func sourceName(_ k: Double) -> String {
        sources.min(by: { abs(mired($0.kelvin) - mired(k)) < abs(mired($1.kelvin) - mired(k)) })?.name ?? ""
    }

    /// Kelvin no formato que a a6700 aceita (2500–9900 K, passos de 100).
    static func sonyKelvin(_ k: Double) -> Int {
        Int((min(max(k, 2500), 9900) / 100).rounded() * 100)
    }

    /// Tint positivo = luz puxando pro verde, corrigido com M na câmera.
    static func sonyGM(_ tint: Double) -> String {
        let s = max(-7, min(7, Int((tint / 10.0).rounded())))
        if s == 0 { return "0" }
        return s > 0 ? "M\(s)" : "G\(-s)"
    }

    static func tintDescription(_ tint: Double) -> String {
        if abs(tint) < 5 { return "neutra" }
        return tint > 0 ? "puxa pro verde" : "puxa pro magenta"
    }

    static let gels: [(name: String, mired: Double)] = [
        ("1/8 CTO", 20), ("1/4 CTO", 42), ("1/2 CTO", 81), ("Full CTO", 159),
        ("1/8 CTB", -12), ("1/4 CTB", -30), ("1/2 CTB", -68), ("Full CTB", -131)
    ]

    struct GelChoice { let names: [String]; let mired: Double }

    static func bestGel(shift: Double) -> GelChoice {
        var options: [GelChoice] = [GelChoice(names: [], mired: 0)]
        for (i, a) in gels.enumerated() {
            options.append(GelChoice(names: [a.name], mired: a.mired))
            for b in gels[i...] where (a.mired > 0) == (b.mired > 0) {
                options.append(GelChoice(names: [a.name, b.name], mired: a.mired + b.mired))
            }
        }
        // Prefere menos gelatinas quando a diferença é pequena.
        return options.min(by: { cost($0, shift) < cost($1, shift) }) ?? options[0]
    }

    private static func cost(_ g: GelChoice, _ shift: Double) -> Double {
        abs(shift - g.mired) + Double(g.names.count) * 4
    }
}

// MARK: - Profundidade de campo (APS-C)

struct DoFResult {
    let near: Double   // metros
    let far: Double    // metros (infinito = .infinity)
    let hyperfocal: Double
}

enum DoFMath {
    static let coc = 0.02 // mm, APS-C

    static func compute(focal f: Double, aperture n: Double, distance m: Double) -> DoFResult {
        let s = m * 1000
        let h = f * f / (n * coc) + f
        let near = s * (h - f) / (h + s - 2 * f)
        let far = s < h ? s * (h - f) / (h - s) : Double.infinity
        return DoFResult(near: near / 1000, far: far / 1000, hyperfocal: h / 1000)
    }
}

// MARK: - Localização

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 20
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways { manager.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let l = locations.last { location = l }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    var denied: Bool { status == .denied || status == .restricted }
}
