import SwiftUI
import UIKit
import CoreLocation

struct ScoutEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var title: String
    var lines: [String]
    var photo: String?
}

struct ScoutLocation: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var latitude: Double?
    var longitude: Double?
    var notes: String = ""
    var entries: [ScoutEntry] = []
}

final class ScoutStore: ObservableObject {
    static let shared = ScoutStore()

    @Published var locations: [ScoutLocation] = [] { didSet { save() } }
    @Published var currentID: UUID? {
        didSet { UserDefaults.standard.set(currentID?.uuidString, forKey: "scoutCurrent") }
    }

    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var fileURL: URL { docs.appendingPathComponent("scout.json") }
    static var photoDir: URL {
        let u = docs.appendingPathComponent("scout-fotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? JSONDecoder().decode([ScoutLocation].self, from: data) {
            locations = list
        }
        if let s = UserDefaults.standard.string(forKey: "scoutCurrent") { currentID = UUID(uuidString: s) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(locations) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    var current: ScoutLocation? { locations.first { $0.id == currentID } }

    @discardableResult
    func newLocation(name: String? = nil) -> UUID {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        var loc = ScoutLocation(name: (name?.isEmpty == false ? name! : "Locação \(f.string(from: Date()))"))
        if let l = LocationManager.shared.location {
            loc.latitude = l.coordinate.latitude
            loc.longitude = l.coordinate.longitude
        }
        locations.insert(loc, at: 0)
        currentID = loc.id
        return loc.id
    }

    /// Adiciona um registro na locação atual (cria uma se não houver) e devolve o nome dela.
    @discardableResult
    func addEntry(title: String, lines: [String], image: UIImage? = nil, includeSun: Bool = true) -> String {
        if current == nil { newLocation() }
        guard let idx = locations.firstIndex(where: { $0.id == currentID }) else { return "" }
        var loc = locations[idx]
        var all = lines
        if let l = LocationManager.shared.location {
            if includeSun {
                let sun = SunMath.position(date: Date(), lat: l.coordinate.latitude, lon: l.coordinate.longitude)
                all.append("Sol: \(Int(sun.azimuth.rounded()))° (\(SunMath.cardinal(sun.azimuth))), \(Int(sun.elevation.rounded()))° de altura")
            }
            if loc.latitude == nil {
                loc.latitude = l.coordinate.latitude
                loc.longitude = l.coordinate.longitude
            }
        }
        var entry = ScoutEntry(title: title, lines: all)
        if let image, let data = image.jpegData(compressionQuality: 0.8) {
            let name = UUID().uuidString + ".jpg"
            try? data.write(to: Self.photoDir.appendingPathComponent(name))
            entry.photo = name
        }
        loc.entries.insert(entry, at: 0)
        locations[idx] = loc
        return loc.name
    }

    func image(for entry: ScoutEntry) -> UIImage? {
        guard let p = entry.photo else { return nil }
        return UIImage(contentsOfFile: Self.photoDir.appendingPathComponent(p).path)
    }

    func removeLocations(at offsets: IndexSet) {
        for i in offsets {
            for e in locations[i].entries { removePhoto(e) }
            if locations[i].id == currentID { currentID = nil }
        }
        locations.remove(atOffsets: offsets)
    }

    func removeEntries(locationID: UUID, at offsets: IndexSet) {
        guard let i = locations.firstIndex(where: { $0.id == locationID }) else { return }
        for o in offsets { removePhoto(locations[i].entries[o]) }
        locations[i].entries.remove(atOffsets: offsets)
    }

    private func removePhoto(_ e: ScoutEntry) {
        if let p = e.photo { try? FileManager.default.removeItem(at: Self.photoDir.appendingPathComponent(p)) }
    }

    // MARK: PDF

    func exportPDF(_ loc: ScoutLocation) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 40
        let width = page.width - margin * 2
        let safe = loc.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Scout-\(safe.isEmpty ? "locacao" : safe).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let accent = UIColor(red: 0.85, green: 0.45, blue: 0.1, alpha: 1)
        do {
            try renderer.writePDF(to: url) { ctx in
                var y: CGFloat = margin
                ctx.beginPage()

                func ensure(_ h: CGFloat) {
                    if y + h > page.height - margin {
                        ctx.beginPage()
                        y = margin
                    }
                }
                func draw(_ s: String, _ font: UIFont, _ color: UIColor = .black, gap: CGFloat = 4) {
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                    let str = s as NSString
                    let rect = str.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
                    ensure(rect.height)
                    str.draw(with: CGRect(x: margin, y: y, width: width, height: ceil(rect.height)),
                             options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
                    y += ceil(rect.height) + gap
                }

                draw("SCOUT DE LOCAÇÃO · AIOScamera", .systemFont(ofSize: 9, weight: .semibold), accent)
                draw(loc.name, .boldSystemFont(ofSize: 24), gap: 6)
                var meta = loc.created.formatted(date: .long, time: .shortened)
                if let lat = loc.latitude, let lon = loc.longitude {
                    meta += String(format: " · %.5f, %.5f", lat, lon)
                }
                draw(meta, .systemFont(ofSize: 10), .darkGray, gap: 14)

                if let lat = loc.latitude, let lon = loc.longitude {
                    draw("Luz do dia (\(loc.created.formatted(date: .abbreviated, time: .omitted)))", .boldSystemFont(ofSize: 13))
                    for w in SunMath.windows(day: loc.created, lat: lat, lon: lon) {
                        draw("\(w.name): \(w.text)", .systemFont(ofSize: 10.5), .black, gap: 2)
                    }
                    y += 10
                }
                if !loc.notes.isEmpty {
                    draw("Notas", .boldSystemFont(ofSize: 13))
                    draw(loc.notes, .systemFont(ofSize: 10.5), gap: 14)
                }
                for e in loc.entries.reversed() {
                    ensure(40)
                    draw("\(e.title) · \(e.date.formatted(date: .omitted, time: .shortened))", .boldSystemFont(ofSize: 13), accent)
                    for l in e.lines { draw("•  " + l, .systemFont(ofSize: 10.5), .black, gap: 2) }
                    if let img = self.image(for: e), img.size.width > 0 {
                        var w: CGFloat = min(width, 360)
                        var h = w * img.size.height / img.size.width
                        let maxH = page.height - margin * 2 - 20
                        if h > maxH { h = maxH; w = h * img.size.width / img.size.height }
                        y += 4
                        ensure(h)
                        img.draw(in: CGRect(x: margin, y: y, width: w, height: h))
                        y += h
                    }
                    y += 14
                }
            }
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Telas

struct ScoutListView: View {
    @EnvironmentObject var store: ScoutStore
    @State private var showingNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                if store.locations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nenhuma locação ainda").font(.headline)
                        Text("Crie uma locação com o + ou salve uma medição, um quadro do visor ou os horários do sol em qualquer aba. Tudo fica guardado aqui, com GPS e posição do sol, e vira um PDF para mandar pro cliente.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(store.locations) { loc in
                    NavigationLink(value: loc.id) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(loc.name).font(.headline)
                                Text("\(loc.entries.count) registros · \(loc.created.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if loc.id == store.currentID {
                                Text("ATUAL")
                                    .font(.caption2.weight(.bold)).tracking(1)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Theme.accent.opacity(0.2), in: Capsule())
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .onDelete { store.removeLocations(at: $0) }
            }
            .navigationTitle("Scout")
            .navigationDestination(for: UUID.self) { id in ScoutDetailView(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("Nova locação", isPresented: $showingNew) {
                TextField("Nome da locação", text: $newName)
                Button("Criar") { store.newLocation(name: newName); newName = "" }
                Button("Cancelar", role: .cancel) { newName = "" }
            } message: {
                Text("Os próximos registros vão para ela.")
            }
        }
    }
}

struct ScoutDetailView: View {
    @EnvironmentObject var store: ScoutStore
    let id: UUID
    @State private var share: ShareItem?
    @State private var planDate = Date()

    private var index: Int? { store.locations.firstIndex { $0.id == id } }

    var body: some View {
        if let i = index {
            let loc = store.locations[i]
            Form {
                Section("Locação") {
                    TextField("Nome", text: $store.locations[i].name)
                    if store.currentID == id {
                        Label("Recebendo os novos registros", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    } else {
                        Button("Usar como locação atual") { store.currentID = id }
                    }
                    if let lat = loc.latitude, let lon = loc.longitude {
                        HStack {
                            Text(String(format: "%.5f, %.5f", lat, lon)).monospacedDigit().foregroundStyle(.secondary)
                            Spacer()
                            if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=\(loc.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                                Link("Mapas", destination: url)
                            }
                        }
                    }
                    Button("Gravar GPS de onde estou agora") {
                        if let l = LocationManager.shared.location {
                            store.locations[i].latitude = l.coordinate.latitude
                            store.locations[i].longitude = l.coordinate.longitude
                        }
                    }
                }
                if let lat = loc.latitude, let lon = loc.longitude {
                    Section("Luz do dia neste local") {
                        DatePicker("Data", selection: $planDate, displayedComponents: .date)
                        ForEach(SunMath.windows(day: planDate, lat: lat, lon: lon)) { w in
                            HStack {
                                Text(w.name)
                                Spacer()
                                Text(w.text).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
                Section("Notas") {
                    TextEditor(text: $store.locations[i].notes)
                        .frame(minHeight: 90)
                }
                Section("Registros (\(loc.entries.count))") {
                    if loc.entries.isEmpty {
                        Text("Salve medições, quadros do visor ou horários do sol para aparecerem aqui.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(loc.entries) { e in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(e.title).font(.headline)
                                Spacer()
                                Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let img = store.image(for: e) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            ForEach(Array(e.lines.enumerated()), id: \.offset) { _, l in
                                Text(l).font(.footnote)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { store.removeEntries(locationID: id, at: $0) }
                }
                Section {
                    Button {
                        if let url = store.exportPDF(store.locations[i]) { share = ShareItem(url: url) }
                    } label: {
                        Label("Exportar relatório em PDF", systemImage: "doc.richtext")
                    }
                }
            }
            .navigationTitle(loc.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
        } else {
            Text("Locação removida").foregroundStyle(.secondary)
        }
    }
}
