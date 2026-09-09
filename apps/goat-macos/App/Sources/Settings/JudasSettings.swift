import AppKit
import Caprine
import JUDAS
import SwiftUI

struct JudasSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showingDetails = false
    @State private var settingsOpenFailed = false

    let openEngine: () -> Void
    let openMemory: () -> Void
    let openMCP: () -> Void

    private var tokens: Caprine { model.theme.tokens }

    var body: some View {
        Form {
            connectionPolicy
            serviceAccess
            previewControls
            localNetworkPermission
            activityLog
            protectionDetails
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .foregroundStyle(tokens.ink)
        .tint(tokens.tint)
    }

    private var connectionPolicy: some View {
        @Bindable var model = model
        return Section {
            Picker("Connection policy", selection: $model.judasMode) {
                choice(
                    "Configured connections",
                    detail: "Use the services you choose, on this Mac, your local network or the internet."
                ).tag(JudasMode.configured)
                choice(
                    "Local networks only",
                    detail:
                        "Use this Mac, private LAN and Thunderbolt services. Block internet services and MCP processes."
                ).tag(JudasMode.localNetworksOnly)
                choice(
                    "Block connections",
                    detail:
                        "Stop all managed network connections, including local services. Offline files stay available."
                ).tag(JudasMode.blocked)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Connection policy")
        } header: {
            heading("Connection policy", symbol: "shield.lefthalf.filled")
        } footer: {
            note(
                "Changes apply immediately and disconnect active integrations. Reconnect them in Engine, Memory or MCP when ready."
            )
        }
    }

    private var serviceAccess: some View {
        Section {
            accessRow(
                "This Mac, LAN & Thunderbolt", symbol: "network",
                value: model.judasMode == .blocked ? "Blocked" : "Configured services allowed")
            accessRow(
                "Internet services", symbol: "globe",
                value: model.judasMode == .configured ? "Configured services allowed" : "Blocked")
            accessRow(
                "MCP processes", symbol: "terminal",
                value: model.judasMode == .configured ? "Configured processes allowed" : "Blocked")
            ViewThatFits(in: .horizontal) {
                HStack {
                    connectionShortcuts
                }
                VStack(alignment: .leading) {
                    connectionShortcuts
                }
            }
        } header: {
            heading("Service access", symbol: "point.3.connected.trianglepath.dotted")
        } footer: {
            note(
                "This policy applies to your engine, Hindsight and HTTP MCP connections. GOAT never scans your network or phones home. MCP processes can make their own connections, so restricted modes stop them."
            )
        }
    }

    @ViewBuilder private var connectionShortcuts: some View {
        Button("Engine", systemImage: "cpu", action: openEngine)
            .buttonStyle(SecondaryChipButtonStyle())
            .help("Manage engine connections")
        Button("Memory", systemImage: "brain", action: openMemory)
            .buttonStyle(SecondaryChipButtonStyle())
            .help("Manage Hindsight and memory connections")
        Button("MCP", systemImage: "wrench.and.screwdriver", action: openMCP)
            .buttonStyle(SecondaryChipButtonStyle())
            .help("Manage MCP servers and tool permissions")
    }

    private var previewControls: some View {
        @Bindable var model = model
        return Section {
            Toggle("Off-grid previews", isOn: $model.previewsOffGrid)
                .disabled(model.judasMode != .configured)
                .help("Restrict preview content to local resources and loopback addresses on this Mac.")
            accessRow("Preview access now", symbol: "doc.richtext", value: previewSummary)
        } header: {
            heading("Paddock previews", symbol: "rectangle.on.rectangle")
        } footer: {
            VStack(alignment: .leading) {
                note(
                    "With Off-grid off, preview content can load web resources in Configured connections mode. With it on, previews use local content and loopback resources on this Mac; LAN services are not preview resources."
                )
                if model.judasMode != .configured {
                    note(
                        "The connection policy overrides this control. Your Off-grid preference is kept for when you return to Configured connections."
                    )
                }
                note(
                    "Restricted HTML and SVG disable page scripts. Bundled Mermaid diagrams still render. Chat and memory Markdown images remain blocked."
                )
            }
        }
    }

    private var localNetworkPermission: some View {
        Section {
            Text("Allow GOAT in macOS to use LAN and Thunderbolt services such as Hindsight.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("System Settings → Privacy & Security → Local Network → GOAT")
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings", systemImage: "arrow.up.right") {
                openSystemSettings()
            }
            .buttonStyle(SecondaryChipButtonStyle())
            if settingsOpenFailed {
                Text("System Settings could not be opened. Open it from the Apple menu and follow the path above.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            heading("macOS local-network permission", symbol: "desktopcomputer")
        } footer: {
            note(
                "macOS manages this permission separately; JUDAS does not display its current status. If GOAT is not listed, connect a local service to request access. After allowing access, reconnect the service. Block connections still takes precedence inside GOAT."
            )
        }
    }

    private var activityLog: some View {
        Section {
            Button("Show Activity Log", systemImage: "list.bullet.rectangle") {
                model.showActivityLog = true
            }
            .buttonStyle(SecondaryChipButtonStyle())
            Text(
                "Allowed and blocked connections, tool activity and policy changes appear in Hoofprint, GOAT’s Activity Log."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            heading("Activity & privacy", symbol: "list.bullet.rectangle")
        } footer: {
            note(
                "Latest 500 entries, held in memory for this session. Clear or quit to remove them. JUDAS entries exclude prompts, request bodies, credentials, URL paths and tool arguments."
            )
        }
    }

    private var protectionDetails: some View {
        Section {
            DisclosureGroup(isExpanded: $showingDetails) {
                detail(
                    "Local addresses",
                    text:
                        "Local networks only accepts localhost and literal private, link-local and loopback IP addresses, including IPv6. A Thunderbolt address such as 192.168.253.1 is local. Hostname aliases do not automatically count as local."
                )
                detail(
                    "Connection safeguards",
                    text:
                        "Managed HTTP stays bound to the configured scheme, host and port. Redirects are always blocked. These safeguards are always on. Configure the server’s final address if it redirects."
                )
                detail(
                    "Protection scope",
                    text:
                        "JUDAS governs GOAT’s managed connections. External servers, MCP processes and browsers control their own traffic. Even a local server can contact other services. A permitted browser link hands control to that browser. JUDAS cannot recall data already sent."
                )
                detail(
                    "Offline access & diagnostics",
                    text:
                        "Offline files and Hitch’s private local socket remain available in every mode. Turns submitted through Hitch follow JUDAS policy. WebKit reports preview policy and navigation, but not every blocked resource. The Activity Log is not a packet capture."
                )
            } label: {
                Text("Protection details").font(.callout.weight(.medium))
            }
        }
    }

    private var previewSummary: String {
        switch model.judasMode {
        case .configured: model.previewsOffGrid ? "Local content & this Mac" : "Web resources allowed"
        case .localNetworksOnly: "Local content & this Mac"
        case .blocked: "Local content only · network blocked"
        }
    }

    private func choice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.callout.weight(.medium))
            note(detail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).foregroundStyle(tokens.ink)
    }

    private func accessRow(_ title: String, symbol: String, value: String) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(tokens.muted)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label(title, systemImage: symbol)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.callout.weight(.medium))
            note(text)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(tokens.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func openSystemSettings() {
        // Launch only the local system app. This is not a browser or network-policy bypass.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            settingsOpenFailed = true
            return
        }
        settingsOpenFailed = !NSWorkspace.shared.open(url)
    }
}
