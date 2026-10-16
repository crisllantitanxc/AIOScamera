import SwiftUI

@main
struct AIOScameraApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var scout = ScoutStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(scout)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @State private var tab = 0
    @Environment(\.scenePhase) private var scenePhase

    private var foreground: Bool { scenePhase == .active }

    var body: some View {
        TabView(selection: $tab) {
            MeterView(active: tab == 0 && foreground)
                .tabItem { Label("Medidor", systemImage: "camera.metering.spot") }
                .tag(0)
            ViewfinderView(active: tab == 1 && foreground)
                .tabItem { Label("Visor", systemImage: "viewfinder") }
                .tag(1)
            SunView(active: tab == 2 && foreground)
                .tabItem { Label("Sol", systemImage: "sun.max") }
                .tag(2)
            ScoutListView()
                .tabItem { Label("Scout", systemImage: "map") }
                .tag(3)
            ToolsView(active: tab == 4 && foreground)
                .tabItem { Label("Ferramentas", systemImage: "slider.horizontal.3") }
                .tag(4)
        }
        .onAppear { LocationManager.shared.start() }
    }
}

// MARK: - Visual helpers

enum Theme {
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.22)
    static let card = Color(red: 0.11, green: 0.115, blue: 0.13)
    static let good = Color(red: 0.35, green: 0.85, blue: 0.5)
    static let warn = Color(red: 1.0, green: 0.8, blue: 0.3)
    static let bad = Color(red: 1.0, green: 0.42, blue: 0.38)
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.0)
            .foregroundStyle(.secondary)
    }
}

struct BigNumber: View {
    let text: String
    var size: CGFloat = 40
    var color: Color = .primary
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

struct BannerModifier: ViewModifier {
    @Binding var text: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = text {
                Text(t)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                            withAnimation { text = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut, value: text)
    }
}

extension View {
    func banner(_ text: Binding<String?>) -> some View { modifier(BannerModifier(text: text)) }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

func fmt(_ v: Double, _ digits: Int = 1) -> String {
    v.formatted(.number.precision(.fractionLength(digits)))
}

func hm(_ d: Date) -> String {
    d.formatted(date: .omitted, time: .shortened)
}

struct PermissionMessage: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.fill").font(.title)
            Text(text).multilineTextAlignment(.center).font(.subheadline)
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
