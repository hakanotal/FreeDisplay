import SwiftUI

// MARK: - Shared Icon Helper

/// A colored rounded-square SF Symbol icon, consistent with macOS Settings style.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

// MARK: - ExpandableRow

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    let label: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: icon, color: iconColor)
            Text(label).font(.body)
            Spacer()
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(isExpanded ? L("\(label), genişletildi", "\(label), expanded") : L("\(label), daraltıldı", "\(label), collapsed"))
        .accessibilityHint(L("Bu bölümü genişletmek veya daraltmak için tıklayın", "Click to expand or collapse this section"))
        .accessibilityAddTraits(.isButton)
        .help(L("Bu bölümü genişletmek veya daraltmak için tıklayın", "Click to expand or collapse this section"))
    }
}

struct MenuBarView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var virtualDisplayService = VirtualDisplayService.shared
    @ObservedObject private var nightMode = NightModeService.shared
    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showArrangement: Bool = false
    @State private var showVirtualDisplays: Bool = false
    @State private var showAutoBrightness: Bool = false
    @State private var showNightMode: Bool = false
    @State private var showSettings: Bool = false
    @State private var quitHovered = false
    @State private var contentHeight: CGFloat = 0

    private var visibleDisplays: [DisplayInfo] {
        displayManager.displays.filter { !virtualDisplayService.isVirtualDisplay($0.displayID) }
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // 显示器列表
                ForEach(visibleDisplays) { display in
                    VStack(spacing: 0) {
                        DisplayRowView(
                            display: display,
                            isExpanded: expandedDisplayIDs.contains(display.displayID),
                            onToggleExpand: {
                                if expandedDisplayIDs.contains(display.displayID) {
                                    expandedDisplayIDs.remove(display.displayID)
                                } else {
                                    expandedDisplayIDs.insert(display.displayID)
                                }
                            }
                        )

                        if expandedDisplayIDs.contains(display.displayID) {
                            DisplayDetailView(display: display)
                        }
                    }
                }

                // 预设列表 (Phase 19)
                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                PresetListView()

                // 排列显示器 section (Phase 4)
                if visibleDisplays.count > 1 {
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)

                    ExpandableRow(
                        icon: "rectangle.3.offgrid",
                        iconColor: .blue,
                        label: L("Ekranları Düzenle", "Arrange Displays"),
                        isExpanded: $showArrangement
                    )

                    if showArrangement {
                        ArrangementView()
                            .environmentObject(displayManager)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // 组合亮度控制（Phase 2）
                if settings.showCombinedBrightness {
                    CombinedBrightnessView(displays: displayManager.displays)
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)
                }

                // 工具区标题
                Text(L("Araçlar", "Tools"))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                // 虚拟显示器工具入口 (Phase 10)
                ExpandableRow(
                    icon: "display.2",
                    iconColor: .blue,
                    label: L("Sanal Ekranlar", "Virtual Displays"),
                    isExpanded: $showVirtualDisplays
                )

                if showVirtualDisplays {
                    VirtualDisplayView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // 自动亮度入口 (Phase 11)
                ExpandableRow(
                    icon: "sun.and.horizon.fill",
                    iconColor: .orange,
                    label: L("Otomatik Parlaklık", "Auto Brightness"),
                    isExpanded: $showAutoBrightness
                )

                if showAutoBrightness {
                    AutoBrightnessView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Night mode (blue light filter)
                ExpandableRow(
                    icon: "moon.fill",
                    iconColor: nightMode.isActive ? .indigo : .gray,
                    label: L("Gece Modu", "Night Mode"),
                    subtitle: NightModeView.subtitle(for: nightMode),
                    isExpanded: $showNightMode
                )

                if showNightMode {
                    NightModeView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // 设置区 (Phase 12)
                ExpandableRow(
                    icon: "gearshape.fill",
                    iconColor: .gray,
                    label: L("Ayarlar", "Settings"),
                    isExpanded: $showSettings
                )

                if showSettings {
                    SettingsView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // 更新提示 (Phase 12)
                if updateService.hasUpdate, let ver = updateService.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(L("Yeni sürüm v\(ver) mevcut", "New version v\(ver) available"))
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Button(L("Görüntüle", "View")) { updateService.openReleasePage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .help(L("En son sürümü indirip yükleyin", "Download and install the latest version"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }

            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // macOS 27 sizes the MenuBarExtra window to the content's minimum size, and a bare
        // ScrollView's minimum height is 0 (only the footer would show). Pin the ScrollView
        // to the measured content height, capped so long content still scrolls.
        .frame(height: min(contentHeight, 640))

        Divider().opacity(0.3)

        // 版本号与退出（固定在底部，不随内容滚动）
        HStack {
            Text("FreeDisplay v\(updateService.currentVersion)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .accessibilityHidden(true)
                    Text(L("Çıkış", "Quit"))
                }
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(quitHovered ? Color.primary.opacity(0.06) : .clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(quitHovered ? .red : .secondary)
            .onHover { quitHovered = $0 }
            .help(L("FreeDisplay'den çık", "Quit FreeDisplay"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        } // end VStack
        .frame(width: 340)
        .frame(maxHeight: 700)
        .padding(.vertical, 8)
        .topResizeAnchor()
        .onReceive(displayManager.$displays) { newDisplays in
            let validIDs = Set(newDisplays.map { $0.displayID })
            expandedDisplayIDs = expandedDisplayIDs.intersection(validIDs)
        }
        .task {
            if settings.checkUpdatesOnLaunch {
                await updateService.checkForUpdates()
            }
        }
    }
}

private extension View {
    /// Keeps the panel pinned under the menu bar while it grows/shrinks (macOS 26+).
    @ViewBuilder func topResizeAnchor() -> some View {
        if #available(macOS 26.0, *) {
            windowResizeAnchor(.top)
        } else {
            self
        }
    }
}

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    @EnvironmentObject var displayManager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Dil / Language
            HStack(spacing: 6) {
                MenuItemIcon(systemName: "globe", color: .indigo)
                    .accessibilityHidden(true)
                Text(L("Dil", "Language"))
                    .font(.body)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { LanguageStore.shared.language },
                    set: { newValue in
                        LanguageStore.shared.language = newValue
                        displayManager.relocalizeDisplayNames()
                    }
                )) {
                    Text(verbatim: "Türkçe").tag(AppLanguage.tr)
                    Text(verbatim: "English").tag(AppLanguage.en)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .help(L("Arayüz dili", "Interface language"))

            // 开机自启动
            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    if newValue {
                        LaunchService.shared.enable()
                    } else {
                        LaunchService.shared.disable()
                    }
                    settings.launchAtLogin = newValue
                }
            )) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "power", color: .green)
                        .accessibilityHidden(true)
                    Text(L("Girişte otomatik başlat", "Launch at login"))
                        .font(.body)
                    Spacer(minLength: 8)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help(L("Oturum açıldığında FreeDisplay'i otomatik başlat", "Start FreeDisplay automatically at login"))

            // 首次启动提示：建议开启开机自启
            if !settings.launchAtLoginPrompted {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(L("Girişte otomatik başlatma önerilir", "Launch at login is recommended"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(L("Anladım", "Got it")) {
                        settings.launchAtLoginPrompted = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .onAppear {
                    // Mark as prompted so it only shows once
                    // User dismisses manually via "Anladım" button
                }
            }

            // 显示组合亮度
            Toggle(isOn: $settings.showCombinedBrightness) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "sun.min.fill", color: .yellow)
                        .accessibilityHidden(true)
                    Text(L("Birleşik parlaklığı göster", "Show combined brightness"))
                        .font(.body)
                    Spacer(minLength: 8)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help(L("Menüde tüm ekranlar için tek bir parlaklık kaydırıcısı göster", "Show a single brightness slider for all displays in the menu"))

            // 启动时检查更新
            Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "arrow.clockwise.circle", color: .blue)
                        .accessibilityHidden(true)
                    Text(L("Açılışta güncellemeleri denetle", "Check for updates on launch"))
                        .font(.body)
                    Spacer(minLength: 8)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help(L("Her açılışta yeni sürüm olup olmadığını otomatik denetle", "Automatically check for a new version on every launch"))
        }
        .padding(.vertical, 6)
    }
}

// MARK: - DisplayRowView

struct DisplayRowView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var isHovered: Bool = false

    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                    .rotationEffect(Angle(degrees: isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .accessibilityHidden(true)

                MenuItemIcon(systemName: display.isBuiltin ? "laptopcomputer" : "display", color: .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let mode = display.currentDisplayMode {
                        Text(mode.resolutionString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                if display.isMain {
                    Text(L("Ana", "Main"))
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(3)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
            .help(L("Ekran kontrol panelini genişlet", "Expand display controls"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(L("Sistem Ayarları'nda Aç", "Open in System Settings"), systemImage: "display")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.name, forType: .string)
            } label: {
                Label(L("Ekran Adını Kopyala", "Copy Display Name"), systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel(L("Ekran: \(display.name)\(display.isMain ? ", ana ekran" : "")\(isExpanded ? ", genişletildi" : ", daraltıldı")", "Display: \(display.name)\(display.isMain ? ", main display" : "")\(isExpanded ? ", expanded" : ", collapsed")"))
        .accessibilityHint(L("Kontrol panelini genişletmek için tıklayın", "Click to expand the control panel"))
        .accessibilityAddTraits(.isButton)
    }
}
