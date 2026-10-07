import SwiftUI

/// Visual display arrangement view.
/// Shows all active displays as scaled thumbnails on a canvas. Dragging a display snaps it
/// flush against the nearest edge of another display (like System Settings); the whole
/// layout is applied in one transaction. Secondary displays get a "Set as main" button.
struct ArrangementView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var settings = SettingsService.shared
    @State private var drag: DragState?
    /// Layout shown while a drop is being applied, so the thumbnail stays where it was dropped.
    @State private var pendingFrames: [CGDirectDisplayID: CGRect]?
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var errorTask: Task<Void, Never>?

    private let canvasHeight: CGFloat = 160
    private static let canvasSpace = "arrangementCanvas"

    /// Mirror targets share their source's frame, so only the others are arranged.
    private var arrangedDisplays: [DisplayInfo] {
        displayManager.displays.filter { !$0.isMirrorTarget }
    }

    private var showsAutoArrangeToggle: Bool {
        arrangedDisplays.contains { $0.isBuiltin } && arrangedDisplays.contains { !$0.isBuiltin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                canvas(size: geo.size)
            }
            .frame(height: canvasHeight)

            if let err = errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .transition(Disclosure.content)
            }

            if showsAutoArrangeToggle {
                Toggle(isOn: Binding(
                    get: { settings.autoArrangeExternalAbove },
                    set: { newValue in
                        settings.autoArrangeExternalAbove = newValue
                        if newValue {
                            Task { await displayManager.arrangeExternalAboveBuiltin() }
                        }
                    }
                )) {
                    Text(L("Harici ekranları dahili ekranın üstünde tut", "Keep external displays above built-in"))
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 4)
                .help(L("Bağlandığında veya çözünürlük değiştiğinde harici ekranları dahili ekranın üstüne dizer. Elle düzenleyince kapanır.",
                        "Lines up external displays above the built-in display when they connect or change resolution. Turns off when you arrange displays yourself."))
            }

            // "Set as main display" for non-main displays
            ForEach(arrangedDisplays.filter { !$0.isMain }) { display in
                Button(action: { setMain(display) }) {
                    Label(L("Ana ekran yap: \(display.name)", "Set as main display: \(display.name)"), systemImage: "star.fill")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isApplying)
                .help(L("Bu ekranı ana ekran yap", "Make this the main display"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Canvas

    private func canvas(size: CGSize) -> some View {
        let frames = drag?.baseFrames ?? pendingFrames ?? displayManager.arrangementFrames
        let mapping = drag?.mapping ?? CanvasMapping(frames: Array(frames.values), canvasSize: size)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.underPageBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            if let mapping {
                // Where the dragged display will land.
                if let target = drag?.snapped {
                    let rect = mapping.canvasRect(target)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                ForEach(arrangedDisplays) { display in
                    if let frame = frames[display.displayID] {
                        let rect = mapping.canvasRect(frame)
                        let offset = drag?.id == display.displayID ? drag?.translation ?? .zero : .zero
                        DisplayThumbnailView(display: display, isDragged: drag?.id == display.displayID)
                            .frame(width: max(rect.width, 24), height: max(rect.height, 16))
                            .contentShape(Rectangle())
                            .gesture(dragGesture(for: display.displayID, frames: frames, mapping: mapping))
                            .position(x: rect.midX + offset.width, y: rect.midY + offset.height)
                            .help(L("Ekran: \(display.name)", "Display: \(display.name)"))
                    }
                }
            }
        }
        .coordinateSpace(name: Self.canvasSpace)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Dragging

    private func dragGesture(
        for id: CGDirectDisplayID,
        frames: [CGDirectDisplayID: CGRect],
        mapping: CanvasMapping
    ) -> some Gesture {
        // Measured in the canvas space: the thumbnail moves under the pointer while dragging.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                guard !isApplying else { return }
                var state = drag?.id == id ? drag! : DragState(id: id, baseFrames: frames, mapping: mapping)
                state.translation = value.translation
                state.snapped = state.snappedFrame()
                drag = state
            }
            .onEnded { value in
                guard var state = drag, state.id == id else { return }
                state.translation = value.translation
                state.snapped = state.snappedFrame()
                withAnimation(.easeOut(duration: 0.15)) { drag = nil }
                commit(state)
            }
    }

    /// Applies the dropped position. An invalid or unchanged drop just animates back.
    private func commit(_ state: DragState) {
        guard let target = state.snapped,
              let base = state.baseFrames[state.id],
              target.origin != base.origin,
              let mainID = displayManager.mainDisplayID else { return }

        var newFrames = state.baseFrames
        newFrames[state.id] = target
        pendingFrames = newFrames
        isApplying = true
        Task { @MainActor in
            let ok = await ArrangementService.shared.apply(frames: newFrames, mainID: mainID)
            if ok {
                // The user arranged the displays themselves; stop re-applying the automatic layout.
                settings.autoArrangeExternalAbove = false
                displayManager.refreshDisplays()
            } else {
                showError(L("Ekranlar düzenlenemedi, tekrar deneyin", "Couldn't arrange displays, please try again"))
            }
            withAnimation(.easeOut(duration: 0.15)) { pendingFrames = nil }
            isApplying = false
        }
    }

    private func setMain(_ display: DisplayInfo) {
        guard !isApplying else { return }
        isApplying = true
        Task { @MainActor in
            let ok = await ArrangementService.shared.setMainDisplay(
                display.displayID,
                frames: displayManager.arrangementFrames
            )
            if ok {
                displayManager.refreshDisplays()
            } else {
                showError(L("Ana ekran ayarlanamadı", "Couldn't set main display"))
            }
            isApplying = false
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        errorTask?.cancel()
        errorTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            errorMessage = nil
        }
    }
}

// MARK: - Drag state & canvas mapping

/// A drag in progress. The frames and canvas mapping are frozen at drag start so the
/// canvas doesn't rescale under the pointer.
private struct DragState {
    let id: CGDirectDisplayID
    let baseFrames: [CGDirectDisplayID: CGRect]
    let mapping: CanvasMapping
    var translation: CGSize = .zero
    var snapped: CGRect?

    /// The dragged display's frame at the pointer, snapped to a valid spot.
    func snappedFrame() -> CGRect? {
        guard let base = baseFrames[id] else { return nil }
        let proposed = base.offsetBy(dx: translation.width / mapping.scale,
                                     dy: translation.height / mapping.scale)
        let others = baseFrames.filter { $0.key != id }.map(\.value)
        // Align when within ~8 canvas pixels of an edge or center.
        return ArrangementLayout.snap(proposed, others: others, alignThreshold: 8 / mapping.scale)
    }
}

/// Maps global display coordinates (points) to the canvas, fitting all frames with padding.
private struct CanvasMapping {
    let scale: CGFloat
    let worldOrigin: CGPoint
    let canvasOffset: CGPoint

    init?(frames: [CGRect], canvasSize: CGSize, padding: CGFloat = 16) {
        guard let first = frames.first else { return nil }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        let availW = canvasSize.width - padding * 2
        let availH = canvasSize.height - padding * 2
        guard union.width > 0, union.height > 0, availW > 0, availH > 0 else { return nil }
        scale = min(availW / union.width, availH / union.height)
        worldOrigin = union.origin
        canvasOffset = CGPoint(x: padding + (availW - union.width * scale) / 2,
                               y: padding + (availH - union.height * scale) / 2)
    }

    func canvasRect(_ rect: CGRect) -> CGRect {
        CGRect(x: canvasOffset.x + (rect.minX - worldOrigin.x) * scale,
               y: canvasOffset.y + (rect.minY - worldOrigin.y) * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }
}

// MARK: - Display Thumbnail

private struct DisplayThumbnailView: View {
    let display: DisplayInfo
    let isDragged: Bool

    var body: some View {
        ZStack {
            // Background fill
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    display.isBuiltin
                    ? AnyShapeStyle(LinearGradient(
                        colors: [.blue.opacity(0.75), .purple.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isDragged ? Color.accentColor : (display.isMain ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.4)),
                            lineWidth: isDragged ? 2 : (display.isMain ? 1.5 : 1)
                        )
                )

            // Decorative top bar on external displays (bezel look)
            if !display.isBuiltin {
                VStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 3)
                    Spacer()
                }
                .padding(.horizontal, 3)
                .padding(.top, 3)
            }

            // Display name + main-display badge
            VStack(spacing: 2) {
                Text(display.name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(display.isBuiltin ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if display.isMain {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 5))
                        Text(L("Ana", "Main"))
                            .font(.system(size: 6))
                    }
                    .foregroundColor(display.isBuiltin ? .white.opacity(0.9) : .blue)
                }
            }
            .padding(3)
        }
        .opacity(isDragged ? 0.85 : 1.0)
        .shadow(color: .black.opacity(isDragged ? 0.3 : 0.05), radius: isDragged ? 6 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDragged)
    }
}
