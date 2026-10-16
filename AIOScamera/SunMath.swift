import Foundation

struct SunPosition {
    /// Graus a partir do norte, sentido horário.
    let azimuth: Double
    /// Graus acima do horizonte (com refração).
    let elevation: Double
}

struct SunWindow: Identifiable {
    let id = UUID()
    let name: String
    let start: Date?
    let end: Date?

    var text: String {
        switch (start, end) {
        case let (s?, e?): return "\(hm(s)) – \(hm(e))"
        case let (s?, nil): return hm(s)
        case let (nil, e?): return "até \(hm(e))"
        default: return "—"
        }
    }
}

struct SunPathPoint {
    let date: Date
    let position: SunPosition
}

/// Algoritmo da NOAA (precisão de ~1 minuto, suficiente para planejar filmagem).
enum SunMath {
    private static let rad = Double.pi / 180
    private static let deg = 180 / Double.pi

    static func position(date: Date, lat: Double, lon: Double) -> SunPosition {
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let t = (jd - 2451545.0) / 36525.0

        var l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        if l0 < 0 { l0 += 360 }
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let mr = m * rad
        let c = sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * mr) * (0.019993 - 0.000101 * t)
            + sin(3 * mr) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let lambda = trueLong - 0.00569 - 0.00478 * sin(omega * rad)
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(omega * rad)
        let decl = asin(sin(eps * rad) * sin(lambda * rad))

        let y = pow(tan(eps * rad / 2), 2)
        let l0r = l0 * rad
        let eqTime = 4 * deg * (y * sin(2 * l0r) - 2 * e * sin(mr) + 4 * e * y * sin(mr) * cos(2 * l0r)
                                - 0.5 * y * y * sin(4 * l0r) - 1.25 * e * e * sin(2 * mr))

        var secs = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400)
        if secs < 0 { secs += 86400 }
        var tst = (secs / 60 + eqTime + 4 * lon).truncatingRemainder(dividingBy: 1440)
        if tst < 0 { tst += 1440 }
        var ha = tst / 4 - 180
        if ha < -180 { ha += 360 }

        let latr = lat * rad
        let har = ha * rad
        let cosZen = min(max(sin(latr) * sin(decl) + cos(latr) * cos(decl) * cos(har), -1), 1)
        let zen = acos(cosZen)

        var az: Double
        let denom = cos(latr) * sin(zen)
        if abs(denom) > 1e-6 {
            let x = min(max((sin(latr) * cos(zen) - sin(decl)) / denom, -1), 1)
            let a = acos(x) * deg
            if ha > 0 {
                az = (a + 180).truncatingRemainder(dividingBy: 360)
            } else {
                az = (540 - a).truncatingRemainder(dividingBy: 360)
            }
        } else {
            az = lat > 0 ? 180 : 0
        }

        let elev = 90 - zen * deg
        return SunPosition(azimuth: az, elevation: elev + refraction(elev))
    }

    private static func refraction(_ e: Double) -> Double {
        let te = tan(e * rad)
        var r: Double
        if e > 85 {
            r = 0
        } else if e > 5 {
            r = 58.1 / te - 0.07 / pow(te, 3) + 0.000086 / pow(te, 5)
        } else if e > -0.575 {
            r = 1735 + e * (-518.2 + e * (103.4 + e * (-12.79 + e * 0.711)))
        } else {
            r = -20.772 / te
        }
        return r / 3600
    }

    static func path(day: Date, lat: Double, lon: Double, stepMinutes: Int = 15) -> [SunPathPoint] {
        let start = Calendar.current.startOfDay(for: day)
        var out: [SunPathPoint] = []
        var minute = 0
        while minute <= 1440 {
            let d = start.addingTimeInterval(Double(minute) * 60)
            out.append(SunPathPoint(date: d, position: position(date: d, lat: lat, lon: lon)))
            minute += stepMinutes
        }
        return out
    }

    /// Horários do dia: blue hour, golden hour, nascer, pôr e sol mais alto.
    static func windows(day: Date, lat: Double, lon: Double) -> [SunWindow] {
        let start = Calendar.current.startOfDay(for: day)
        var elev: [Double] = []
        elev.reserveCapacity(1441)
        for i in 0...1440 {
            elev.append(position(date: start.addingTimeInterval(Double(i) * 60), lat: lat, lon: lon).elevation)
        }

        func crossing(_ h: Double, rising: Bool) -> Date? {
            for i in 1...1440 {
                let a = elev[i - 1], b = elev[i]
                let hit = rising ? (a < h && b >= h) : (a >= h && b < h)
                if hit {
                    let frac = (h - a) / (b - a)
                    return start.addingTimeInterval((Double(i - 1) + frac) * 60)
                }
            }
            return nil
        }

        var maxI = 0
        for i in 0...1440 where elev[i] > elev[maxI] { maxI = i }
        let noon = start.addingTimeInterval(Double(maxI) * 60)

        return [
            SunWindow(name: "Blue hour (manhã)", start: crossing(-6, rising: true), end: crossing(-4, rising: true)),
            SunWindow(name: "Golden hour (manhã)", start: crossing(-4, rising: true), end: crossing(6, rising: true)),
            SunWindow(name: "Nascer do sol", start: crossing(-0.833, rising: true), end: nil),
            SunWindow(name: "Sol mais alto (\(Int(elev[maxI].rounded()))°)", start: noon, end: nil),
            SunWindow(name: "Golden hour (tarde)", start: crossing(6, rising: false), end: crossing(-4, rising: false)),
            SunWindow(name: "Pôr do sol", start: crossing(-0.833, rising: false), end: nil),
            SunWindow(name: "Blue hour (noite)", start: crossing(-4, rising: false), end: crossing(-6, rising: false))
        ]
    }

    static func cardinal(_ az: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "L", "ESE", "SE", "SSE", "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]
        let i = Int(((az.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
        return names[i]
    }

    static func cardinalName(_ az: Double) -> String {
        let names = ["norte", "nordeste", "leste", "sudeste", "sul", "sudoeste", "oeste", "noroeste"]
        let i = Int(((az.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return names[i]
    }

    static func lightTip(_ elevation: Double) -> String {
        switch elevation {
        case ..<(-0.8): return "Sol abaixo do horizonte. Luz suave e fria do céu."
        case ..<6: return "Sol bem baixo: luz quente e suave, ótima pra contraluz e rosto."
        case ..<20: return "Luz lateral e quente, sombras longas. Boa pra textura e silhueta."
        case ..<50: return "Luz média. Use o sol como contraluz e rebata no rosto."
        default: return "Sol alto e duro, sombra embaixo dos olhos. Procure sombra aberta ou difusor."
        }
    }
}
