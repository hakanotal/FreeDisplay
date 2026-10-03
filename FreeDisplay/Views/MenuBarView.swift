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
        .accessibilityLabel(isExpanded ? "\(label), genişletildi" : "\(label), daraltıldı")
        .accessibilityHint("Bu bölümü genişletmek veya daraltmak için tıklayın")
        .accessibilityAddTraits(.isButton)
        .help("Bu bölümü genişletmek veya daraltmak için tıklayın")
    }
}

struct MenuBarView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var virtualDisplayService = VirtualDisplayService.shared
    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showArrangement: Bool = false
    @State private var showVirtualDisplays: Bool = false
    @State private var showAutoBrightness: Bool = false
    @State private var showSettings: Bool = false
    @State private var quitHovered = false

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
                        label: "Ekranları Düzenle",
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
                Text("Araçlar")
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
                    label: "Sanal Ekranlar",
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
                    label: "Otomatik Parlaklık",
                    isExpanded: $showAutoBrightness
                )

                if showAutoBrightness {
                    AutoBrightnessView()
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
                    label: "Ayarlar",
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
                        Text("Yeni sürüm v\(ver) mevcut")
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Button("Görüntüle") { updateService.openReleasePage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .help("En son sürümü indirip yükleyin")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }

            }
        }

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
                    Text("Çıkış")
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
            .help("FreeDisplay'den çık")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        } // end VStack
        .frame(width: 340)
        .frame(maxHeight: 700)
        .padding(.vertical, 8)
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

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    Text("Girişte otomatik başlat")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Oturum açıldığında FreeDisplay'i otomatik başlat")

            // 首次启动提示：建议开启开机自启
            if !settings.launchAtLoginPrompted {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Girişte otomatik başlatma önerilir")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Anladım") {
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
                    Text("Birleşik parlaklığı göster")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Menüde tüm ekranlar için tek bir parlaklık kaydırıcısı göster")

            // 启动时检查更新
            Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "arrow.clockwise.circle", color: .blue)
                        .accessibilityHidden(true)
                    Text("Açılışta güncellemeleri denetle")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Her açılışta yeni sürüm olup olmadığını otomatik denetle")

            // Türkçe çeviri katkısı
            Button {
                if let url = URL(string: "https://github.com/hakanotal") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Türkçe çeviri: @hakanotal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .help("github.com/hakanotal adresini aç")
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
                    Text("Ana")
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
            .help("Ekran kontrol panelini genişlet")
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
                Label("Sistem Ayarları'nda Aç", systemImage: "display")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.name, forType: .string)
            } label: {
                Label("Ekran Adını Kopyala", systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel("Ekran: \(display.name)\(display.isMain ? ", ana ekran" : "")\(isExpanded ? ", genişletildi" : ", daraltıldı")")
        .accessibilityHint("Kontrol panelini genişletmek için tıklayın")
        .accessibilityAddTraits(.isButton)
    }
}
