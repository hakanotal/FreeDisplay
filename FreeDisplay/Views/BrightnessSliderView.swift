import SwiftUI
import Combine

struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    @State private var localBrightness: Double
    @State private var isDragging: Bool = false
    @State private var valueHighlighted: Bool = false
    @State private var highlightTask: Task<Void, Never>?

    /// Starts at the known value so the panel doesn't open at 50 % and then jump.
    init(display: DisplayInfo) {
        _display = ObservedObject(wrappedValue: display)
        _localBrightness = State(initialValue: display.brightness)
    }

    /// The slider's binding. Its setter only runs for the user's own changes (drag, click,
    /// keyboard, VoiceOver), never when the value follows the hardware.
    private var sliderValue: Binding<Double> {
        Binding(
            get: { localBrightness },
            set: { newValue in
                localBrightness = newValue
                if isDragging {
                    // Applied on every tick: DDC writes are coalesced (latest value wins).
                    BrightnessService.shared.setBrightness(newValue, for: display)
                } else {
                    BrightnessService.shared.setBrightnessSmooth(newValue, for: display)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 2) {
            // Mode indicator row
            HStack(spacing: 4) {
                Spacer()
                if let badge = controlBadge {
                    Circle()
                        .fill(badge.color)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(badge.text)
                        .font(.caption2)
                        .foregroundColor(badge.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .accessibilityLabel(L("Parlaklık kontrol modu: \(controlBadge?.text ?? "-")", "Brightness control mode: \(controlBadge?.text ?? "-")"))
            .help(L("Sistem: Ekranın kendi arka ışığı\nDDC: Parlaklık doğrudan monitör donanımıyla kontrol edilir\nYazılım: Parlaklık yazılımla ayarlanır",
                    "System: the display's own backlight\nDDC: brightness is controlled directly by the monitor hardware\nSoftware: brightness is adjusted in software"))

            HStack(spacing: 6) {
                let sunIcon: String = {
                    if localBrightness < 30 { return "sun.min" }
                    else if localBrightness < 70 { return "sun.min.fill" }
                    else { return "sun.max.fill" }
                }()
                Image(systemName: sunIcon)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(width: 14)
                    .animation(.easeInOut(duration: 0.2), value: sunIcon)
                    .accessibilityHidden(true)

                Slider(value: sliderValue, in: 5...100, step: 1) { editing in
                    isDragging = editing
                    if !editing {
                        withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = true }
                        highlightTask?.cancel()
                        highlightTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = false }
                        }
                    }
                }
                .accessibilityLabel(L("Ekran parlaklığı", "Display brightness"))
                .accessibilityValue("\(Int(localBrightness))%")
                .help(L("Parlaklığı ayarlamak için sürükleyin", "Drag to adjust brightness"))

                Image(systemName: "sun.max")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                let brightnessLabel: String = {
                    if display.brightnessControl == .software { return L("Yazılım \(Int(localBrightness))%", "Software \(Int(localBrightness))%") }
                    return "\(Int(localBrightness))%"
                }()
                Text(brightnessLabel)
                    .font(.caption)
                    .foregroundColor(valueHighlighted ? .accentColor : .secondary)
                    .frame(width: 76, alignment: .trailing)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: display.displayID) {
            // Pick up changes made with the keyboard keys or the monitor's own buttons.
            await BrightnessService.shared.refreshBrightness(for: display)
        }
        .onChange(of: display.brightness) { _, newValue in
            if !isDragging && abs(newValue - localBrightness) >= 1 {
                localBrightness = newValue
            }
        }
    }

    private var controlBadge: (text: String, color: Color)? {
        switch display.brightnessControl {
        case .native: return (L("Sistem", "System"), .blue)
        case .ddc: return ("DDC", .green)
        case .software: return (L("Yazılım", "Software"), .orange)
        case nil: return nil
        }
    }
}

struct CombinedBrightnessView: View {
    let displays: [DisplayInfo]
    @State private var combinedBrightness: Double
    @State private var isDragging: Bool = false
    @StateObject private var average = AverageBrightness()

    init(displays: [DisplayInfo]) {
        self.displays = displays
        let average = displays.isEmpty ? 50 : displays.map(\.brightness).reduce(0, +) / Double(displays.count)
        _combinedBrightness = State(initialValue: max(5, min(100, average)))
    }

    /// Setter runs only for the user's own changes; see BrightnessSliderView.sliderValue.
    private var sliderValue: Binding<Double> {
        Binding(
            get: { combinedBrightness },
            set: { newValue in
                combinedBrightness = newValue
                for display in displays {
                    if isDragging {
                        BrightnessService.shared.setBrightness(newValue, for: display)
                    } else {
                        BrightnessService.shared.setBrightnessSmooth(newValue, for: display)
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                    .accessibilityHidden(true)
                Text(L("Parlaklık (Birleşik)", "Brightness (Combined)"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(combinedBrightness))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                Slider(value: sliderValue, in: 5...100, step: 1) { editing in
                    isDragging = editing
                }
                .accessibilityLabel(L("Birleşik parlaklık", "Combined brightness"))
                .accessibilityValue("\(Int(combinedBrightness))%")

                Image(systemName: "sun.max")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Follow changes made with the keys, auto brightness, presets or the per-display sliders.
        .onAppear { average.track(displays) }
        .onChange(of: displays.map(\.displayID)) { _, _ in average.track(displays) }
        .onReceive(average.$value) { value in
            if !isDragging, let value, abs(value - combinedBrightness) >= 1 {
                combinedBrightness = max(5, min(100, value))
            }
        }
    }
}

/// The average brightness of a set of displays, updated whenever one of them changes.
@MainActor
private final class AverageBrightness: ObservableObject {
    @Published private(set) var value: Double?
    private var trackedIDs: [CGDirectDisplayID] = []
    private var subscription: AnyCancellable?

    func track(_ displays: [DisplayInfo]) {
        let ids = displays.map(\.displayID)
        guard ids != trackedIDs else { return }
        trackedIDs = ids
        // @Published emits before the property changes: read the values on the next turn.
        subscription = Publishers.MergeMany(displays.map { $0.$brightness.map { _ in () } })
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard !displays.isEmpty else { return }
                self?.value = displays.map(\.brightness).reduce(0, +) / Double(displays.count)
            }
    }
}
