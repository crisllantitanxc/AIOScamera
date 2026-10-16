import SwiftUI

struct ToolsView: View {
    let active: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { FlickerView() } label: {
                        Label("Detector de flicker", systemImage: "waveform.path.ecg")
                    }
                    NavigationLink { GelView() } label: {
                        Label("Gelatinas CTO / CTB", systemImage: "circle.lefthalf.striped.horizontal")
                    }
                    NavigationLink { DoFView() } label: {
                        Label("Profundidade de campo", systemImage: "camera.aperture")
                    }
                }
                Section {
                    NavigationLink { SettingsView() } label: {
                        Label("Câmera e calibração", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Ferramentas")
        }
    }
}

// MARK: - Gelatinas

struct GelView: View {
    @ObservedObject private var last = LastReading.shared
    @State private var cameraK: Double = 5600
    @State private var lightK: Double = 3200

    private var shift: Double { ColorMath.mired(cameraK) - ColorMath.mired(lightK) }
    private var choice: ColorMath.GelChoice { ColorMath.bestGel(shift: shift) }
    private var resultK: Double { 1_000_000 / (ColorMath.mired(lightK) + choice.mired) }

    var body: some View {
        Form {
            Section("Balanço de branco da câmera") {
                kelvinRow($cameraK)
                HStack {
                    Button("5600 K") { cameraK = 5600 }
                    Spacer()
                    Button("3200 K") { cameraK = 3200 }
                }
                .buttonStyle(.bordered)
            }
            Section("Luz que você quer corrigir") {
                kelvinRow($lightK)
                if let k = last.kelvin {
                    Button("Usar a última medição (\(Int((k / 50).rounded() * 50)) K)") { lightK = (k / 50).rounded() * 50 }
                }
                Menu("Escolher tipo de luz") {
                    ForEach(ColorMath.sources) { s in
                        Button("\(s.name) · \(Int(s.kelvin)) K") { lightK = s.kelvin }
                    }
                }
            }
            Section("Resultado") {
                if abs(shift) < 10 {
                    Text("As luzes já combinam. Não precisa de gelatina.")
                        .foregroundStyle(Theme.good)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(shift > 0 ? "A luz está mais fria que a câmera. Esquente com CTO." :
                                         "A luz está mais quente que a câmera. Esfrie com CTB.")
                        BigNumber(text: choice.names.isEmpty ? "Sem gel" : choice.names.joined(separator: " + "), size: 30,
                                  color: shift > 0 ? Theme.accent : Color.cyan)
                        Text("Diferença: \(Int(shift.rounded())) mired. Com o gel a luz fica em ≈ \(Int(resultK.rounded()).formatted()) K.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if let t = last.tint, t > 8 {
                    Text("A última medição puxou pro verde (tint \(Int(t))). Em LED barato ou fluorescente, use Minus Green (1/4 ou 1/2).")
                        .font(.footnote)
                }
            }
            Section {
                Text("Valores médios de CTO/CTB (Rosco/Lee variam um pouco). Para casar um LED com a janela, gele o LED. Para deixar a janela quente como tungstênio, use CTO no vidro.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Gelatinas")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func kelvinRow(_ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Stepper(value: value, in: 1800...10000, step: 100) {
                Text("\(Int(value.wrappedValue).formatted()) K").font(.title3.monospacedDigit().weight(.semibold))
            }
            Slider(value: value, in: 1800...10000, step: 50)
        }
    }
}

// MARK: - Profundidade de campo

struct DoFView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var aperture: Double = 2.8
    @State private var distanceSlider: Double = 0.5

    /// 0,3 m a 30 m em escala logarítmica.
    private var distance: Double { 0.3 * pow(100, distanceSlider) }
    private var r: DoFResult { DoFMath.compute(focal: settings.focal, aperture: aperture, distance: distance) }

    var body: some View {
        Form {
            Section("Lente") {
                Stepper("Distância focal: \(Int(settings.focal)) mm", value: $settings.focal, in: 8...600, step: 1)
                Picker("Diafragma", selection: $aperture) {
                    ForEach(ExposureMath.apertures, id: \.self) { Text(ExposureMath.apertureText($0)).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Foco em \(distanceText(distance))").font(.headline)
                    Slider(value: $distanceSlider, in: 0...1)
                }
            }
            Section("Zona nítida") {
                DoFBar(result: r, distance: distance)
                    .frame(height: 70)
                row("Começa em", distanceText(r.near))
                row("Termina em", r.far.isInfinite ? "infinito" : distanceText(r.far))
                if !r.far.isInfinite {
                    row("Total", distanceText(r.far - r.near))
                    row("Na frente / atrás", "\(distanceText(distance - r.near)) / \(distanceText(r.far - distance))")
                }
                row("Hiperfocal", distanceText(r.hyperfocal))
            }
            Section {
                Text("Na a6700 (APS-C), \(Int(settings.focal))mm \(ExposureMath.apertureText(aperture)) dá o mesmo enquadramento e desfoque de \(Int((settings.focal * 1.5).rounded()))mm \(ExposureMath.apertureText(aperture * 1.5)) no full frame. Focando na hiperfocal, fica nítido de \(distanceText(r.hyperfocal / 2)) ao infinito.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Profundidade de campo")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { aperture = settings.aperture }
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).monospacedDigit().foregroundStyle(.secondary) }
    }

    private func distanceText(_ m: Double) -> String {
        if m.isInfinite { return "∞" }
        if m < 1 { return "\(Int((m * 100).rounded())) cm" }
        return fmt(m, m < 10 ? 2 : 1) + " m"
    }
}

struct DoFBar: View {
    let result: DoFResult
    let distance: Double

    var body: some View {
        Canvas { ctx, size in
            let maxD = max(distance * 2.2, result.far.isInfinite ? distance * 3 : min(result.far * 1.2, distance * 6))
            func x(_ d: Double) -> CGFloat { 20 + CGFloat(min(d, maxD) / maxD) * (size.width - 30) }
            let midY = size.height / 2
            var axis = Path()
            axis.move(to: CGPoint(x: 20, y: midY)); axis.addLine(to: CGPoint(x: size.width - 10, y: midY))
            ctx.stroke(axis, with: .color(.white.opacity(0.3)), lineWidth: 1)
            let x0 = x(result.near)
            let x1 = result.far.isInfinite ? size.width - 10 : x(result.far)
            ctx.fill(Path(roundedRect: CGRect(x: x0, y: midY - 12, width: max(2, x1 - x0), height: 24), cornerRadius: 6),
                     with: .color(Theme.accent.opacity(0.35)))
            var focus = Path()
            focus.move(to: CGPoint(x: x(distance), y: midY - 20)); focus.addLine(to: CGPoint(x: x(distance), y: midY + 20))
            ctx.stroke(focus, with: .color(Theme.accent), lineWidth: 2)
            ctx.draw(Text(Image(systemName: "camera.fill")).foregroundColor(.white), at: CGPoint(x: 10, y: midY))
            ctx.draw(Text("foco").font(.caption2).foregroundColor(Theme.accent), at: CGPoint(x: x(distance), y: midY + 30))
        }
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Sony a6700") {
                Picker("Perfil", selection: $settings.profile) {
                    ForEach(CameraProfile.allCases) { Text($0.name).tag($0) }
                }
                Picker("Quadros por segundo", selection: $settings.fps) {
                    ForEach(AppSettings.fpsOptions, id: \.self) { Text("\(Int($0))p").tag($0) }
                }
                Stepper("Ângulo do obturador: \(Int(settings.shutterAngle))°", value: $settings.shutterAngle, in: 45...360, step: 15)
                Text("Obturador na câmera: \(ExposureMath.shutterText(settings.cameraShutter))")
                    .foregroundStyle(.secondary)
                Picker("Diafragma padrão", selection: $settings.aperture) {
                    ForEach(ExposureMath.apertures, id: \.self) { Text(ExposureMath.apertureText($0)).tag($0) }
                }
                Text("ISO base: S-Log3 800, S-Cinetone e padrão 100. A a6700 tem um ISO base só por perfil.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Compensação de exposição") {
                Stepper("\(settings.exposureComp >= 0 ? "+" : "")\(fmt(settings.exposureComp, 1)) EV",
                        value: $settings.exposureComp, in: -2...3, step: 1.0 / 3.0)
                Text("Em S-Log3 muita gente expõe +1 a +1,7 EV acima do fotômetro para limpar o ruído nas sombras. O medidor soma isso no ISO e no ND sugeridos.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Stepper("Kelvin: \(settings.kelvinOffset >= 0 ? "+" : "")\(Int(settings.kelvinOffset)) K",
                        value: $settings.kelvinOffset, in: -1500...1500, step: 50)
                Stepper("Tint: \(settings.tintOffset >= 0 ? "+" : "")\(Int(settings.tintOffset))",
                        value: $settings.tintOffset, in: -60...60, step: 2)
                Toggle("Inverter sinal do tint", isOn: $settings.invertTint)
                Stepper("Exposição: \(settings.evOffset >= 0 ? "+" : "")\(fmt(settings.evOffset, 1)) EV",
                        value: $settings.evOffset, in: -3...3, step: 1.0 / 3.0)
                Button("Zerar calibração", role: .destructive) { settings.resetCalibration() }
            } header: {
                Text("Calibração com a sua a6700")
            } footer: {
                Text("""
                1. Coloque um papel branco sob a luz.
                2. Na a6700, faça um balanço de branco personalizado nesse papel. A câmera mostra o Kelvin e o ajuste G-M que mediu.
                3. Meça o mesmo papel no Medidor e ajuste o offset de Kelvin até bater. Se o tint sair com o lado trocado (verde vs. magenta), ligue "Inverter sinal".
                4. Para a exposição, compare o ISO sugerido com o fotômetro da câmera no mesmo ponto e ajuste o offset de EV.
                """)
            }
        }
        .navigationTitle("Câmera e calibração")
        .navigationBarTitleDisplayMode(.inline)
    }
}
