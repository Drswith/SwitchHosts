import AppKit
import SwiftUI
import SwitchHostsCore

/// Preferences, opened from the app menu (⌘,). The four tabs follow 5.0.2:
/// General, Commands, Proxy, and Advanced. Each control writes its key through
/// the core as soon as it changes; the proxy address and the command text are
/// saved when the user commits them.
struct PreferencesView: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            CommandsTab(model: model)
                .tabItem { Label("Commands", systemImage: "terminal") }
            ProxyTab(model: model)
                .tabItem { Label("Proxy", systemImage: "network") }
            AdvancedTab(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 540)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var model: HostsModel

    @State private var loaded = false
    @State private var launchAtLogin = false
    @State private var hideAtLaunch = false
    @State private var hideDock = false
    @State private var quitOnClose = false
    @State private var theme = "system"
    @State private var writeMode = "append"
    @State private var choiceMode = 2
    @State private var autoCheckUpdate = true
    @State private var useSystemFrame = false
    @State private var language = "system"
    @State private var languageAtLaunch = "system"
    @State private var helperStatus = ""
    @State private var updateMessage = ""
    @State private var updateURL: URL?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { value in
                        do {
                            try LoginItem.setEnabled(value)
                        } catch {
                            launchAtLogin = LoginItem.isEnabled
                            model.errorMessage = error.localizedDescription
                            return
                        }
                        Task { await model.updateConfig(["launch_at_login": value]) }
                    }
                Toggle("Hide at Launch", isOn: $hideAtLaunch)
                    .onChange(of: hideAtLaunch) { value in
                        Task { await model.updateConfig(["hide_at_launch": value]) }
                    }
                Toggle("Hide Dock Icon", isOn: $hideDock)
                    .onChange(of: hideDock) { value in
                        DockIcon.apply(hidden: value)
                        Task { await model.updateConfig(["hide_dock_icon": value]) }
                    }
                Toggle("Quit App When Main Window Is Closed", isOn: $quitOnClose)
                    .onChange(of: quitOnClose) { value in
                        AppBehavior.quitOnClose = value
                        Task { await model.updateConfig(["quit_on_close": value]) }
                    }
                Picker("Theme", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: theme) { value in
                    AppTheme.apply(value)
                    Task { await model.updateConfig(["theme": value]) }
                }
                Toggle("Use System Window Frame", isOn: $useSystemFrame)
                    .onChange(of: useSystemFrame) { value in
                        Task { await model.savePreference(["use_system_window_frame": value]) }
                    }
                Picker("Language", selection: $language) {
                    Text("Follow System").tag("system")
                    Text("简体中文").tag("zh_CN")
                    Text("English").tag("en_US")
                }
                .onChange(of: language) { value in
                    applyLanguage(value)
                    Task { await model.savePreference(["locale": value == "system" ? NSNull() : value]) }
                }
                if language != languageAtLaunch {
                    HStack {
                        Text("The new language applies after SwitchHosts restarts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppRelaunch.restart() }
                    }
                }
            }

            Section {
                Picker("Write Mode", selection: $writeMode) {
                    Text("Append").tag("append")
                    Text("Overwrite").tag("overwrite")
                }
                .pickerStyle(.segmented)
                .onChange(of: writeMode) { value in
                    Task { await model.updateConfig(["write_mode": value]) }
                }
                Text(writeMode == "append"
                     ? "Append the new records to the end of the system hosts file."
                     : "Overwrite the system hosts file with the new records.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Choice Mode", selection: $choiceMode) {
                    Text("Single").tag(1)
                    Text("Multiple").tag(2)
                }
                .pickerStyle(.segmented)
                .onChange(of: choiceMode) { value in
                    Task { await model.updateConfig(["choice_mode": value]) }
                }
                Text("Only applies to top-level items; each folder can set its own choice mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically Check for Updates", isOn: $autoCheckUpdate)
                    .onChange(of: autoCheckUpdate) { value in
                        Task { await model.updateConfig(["auto_check_update": value]) }
                    }
                Text("When enabled, SwitchHosts will remind you when a new version is available and will not download or install updates automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check for Updates") {
                    Task {
                        let result = await model.checkForUpdate()
                        updateMessage = result.message
                        updateURL = result.url
                    }
                }
                if !updateMessage.isEmpty {
                    Text(updateMessage).font(.callout).foregroundStyle(.secondary)
                }
                if let url = updateURL {
                    Button("Open Release Page") { NSWorkspace.shared.open(url) }
                }
            }

            Section("Background Helper") {
                Text(helperLabel(helperStatus))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Install") { runHelper("helper_install") }
                    Button("Reinstall") { runHelper("helper_repair") }
                    Button("Remove") { runHelper("helper_uninstall") }
                }
                Text("Installs a small background helper so automatic remote-hosts updates can be applied without asking for your password each time. Requires macOS 13 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        let config = await model.loadConfig()
        launchAtLogin = LoginItem.isEnabled
        hideAtLaunch = config["hide_at_launch"] as? Bool ?? false
        hideDock = config["hide_dock_icon"] as? Bool ?? false
        quitOnClose = config["quit_on_close"] as? Bool ?? false
        theme = config["theme"] as? String ?? "system"
        writeMode = config["write_mode"] as? String ?? "append"
        choiceMode = config["choice_mode"] as? Int ?? 2
        autoCheckUpdate = config["auto_check_update"] as? Bool ?? true
        useSystemFrame = config["use_system_window_frame"] as? Bool ?? false
        language = config["locale"] as? String ?? "system"
        languageAtLaunch = language
        loaded = true
        helperStatus = await model.helperCommand("helper_status")
    }

    /// The app's language is read from the AppleLanguages default when it starts.
    /// Writing it here takes effect on the next launch.
    private func applyLanguage(_ value: String) {
        switch value {
        case "zh_CN": UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case "en_US": UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        default: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// The label for a helper status code from the core. Failure messages from
    /// install and removal arrive already translated, so they are shown as they are.
    private func helperLabel(_ status: String) -> LocalizedStringKey {
        switch status {
        case "": return "Checking…"
        case "not_supported": return "Not available on this build or macOS version."
        case "not_installed": return "Not installed"
        case "requires_approval": return "Approve in System Settings → Login Items"
        case "installed_current": return "Installed"
        case "installed_outdated": return "Update available"
        case "installed_unreachable": return "Installed but not responding — reinstall"
        default: return LocalizedStringKey(status)
        }
    }

    private func runHelper(_ command: String) {
        Task {
            helperStatus = await model.helperCommand(command)
        }
    }
}

// MARK: - Commands

/// The command that runs after each apply, and the record of its runs.
private struct CommandsTab: View {
    @ObservedObject var model: HostsModel

    @State private var command = ""
    @State private var savedCommand = ""
    @State private var showHistory = false
    @State private var runs: [CommandRun] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commands After Hosts Are Applied")
                .font(.headline)
            Text("The following system commands will run after hosts are applied:")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $command)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Save") {
                    Task {
                        await model.updateConfig(["cmd_after_hosts_apply": command])
                        savedCommand = command
                    }
                }
                .disabled(command == savedCommand)
            }

            Divider()

            HStack {
                Button(showHistory ? "Hide History" : "Show History") {
                    showHistory.toggle()
                    if showHistory { Task { await reload() } }
                }
                Spacer()
                if showHistory {
                    Button("Clear History", role: .destructive) {
                        Task {
                            await model.clearCommandRuns()
                            await reload()
                        }
                    }
                    .disabled(runs.isEmpty)
                }
            }
            if showHistory {
                if runs.isEmpty {
                    Text("No Records")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List(runs) { run in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: run.success ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(run.success ? .green : .red)
                                Text(run.date.formatted(date: .numeric, time: .standard))
                            }
                            let output = [run.stdout, run.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                            Text(output.isEmpty ? " " : output)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                        .contextMenu {
                            Button("Delete") {
                                Task {
                                    await model.deleteCommandRun(run.id)
                                    await reload()
                                }
                            }
                        }
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .padding(20)
        .task {
            let config = await model.loadConfig()
            command = config["cmd_after_hosts_apply"] as? String ?? ""
            savedCommand = command
            await reload()
        }
    }

    private func reload() async {
        runs = await model.commandRuns()
    }
}

// MARK: - Proxy

/// Routes remote hosts downloads, URL imports, and update checks through a proxy.
private struct ProxyTab: View {
    @ObservedObject var model: HostsModel

    @State private var loaded = false
    @State private var useProxy = false
    @State private var proxyProtocol = "http"
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var proxyStatus = ""

    var body: some View {
        Form {
            Section {
                Toggle("Use Proxy", isOn: $useProxy)
                    .onChange(of: useProxy) { value in
                        Task { await model.updateConfig(["use_proxy": value]) }
                    }
                Text("If enabled, remote Hosts downloads and app update checks/downloads will connect through the proxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Protocol", selection: $proxyProtocol) {
                    Text("HTTP").tag("http")
                    Text("HTTPS").tag("https")
                    Text("SOCKS5").tag("socks5")
                }
                .disabled(!useProxy)
                .onChange(of: proxyProtocol) { value in
                    Task { await model.updateConfig(["proxy_protocol": value]) }
                }
                TextField("Host", text: $proxyHost)
                    .disabled(!useProxy)
                    .onSubmit(saveProxyAddress)
                TextField("Port", text: $proxyPort)
                    .disabled(!useProxy)
                    .onSubmit(saveProxyAddress)
                if !proxyStatus.isEmpty {
                    Text(proxyStatus).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .onDisappear(perform: saveProxyAddress)
    }

    private func load() async {
        let config = await model.loadConfig()
        useProxy = config["use_proxy"] as? Bool ?? false
        proxyProtocol = config["proxy_protocol"] as? String ?? "http"
        proxyHost = config["proxy_host"] as? String ?? ""
        let savedPort = config["proxy_port"] as? Int ?? 0
        proxyPort = savedPort > 0 ? String(savedPort) : ""
        loaded = true
    }

    /// Saves the proxy host and port. An empty port means no proxy port is set.
    private func saveProxyAddress() {
        guard loaded else { return }
        let host = proxyHost.trimmingCharacters(in: .whitespaces)
        let digits = proxyPort.trimmingCharacters(in: .whitespaces)
        let port = digits.isEmpty ? 0 : (Int(digits) ?? -1)
        guard port == 0 || (1...65535).contains(port) else {
            proxyStatus = String(localized: "Port must be between 1 and 65535.")
            return
        }
        proxyStatus = ""
        Task { await model.updateConfig(["proxy_host": host, "proxy_port": port]) }
    }
}

// MARK: - Advanced

/// Domain resolution, startup refresh, tray title, the local HTTP API, and where the data lives.
private struct AdvancedTab: View {
    @ObservedObject var model: HostsModel

    @State private var loaded = false
    @State private var dnsProvider = "alidns"
    @State private var dnsCustomURL = ""
    @State private var refreshOnLaunch = false
    @State private var removeDuplicates = false
    @State private var showTitleOnTray = false
    @State private var syncChildren = false
    @State private var httpOn = false
    @State private var httpOnlyLocal = true
    @State private var httpPort = "50761"
    @State private var httpStatus = ""
    @State private var dataDir: DataDirStatus?
    @State private var sendUsageData = false
    @State private var trayShortcut = true

    var body: some View {
        Form {
            Section {
                Picker("Domain DNS resolver", selection: $dnsProvider) {
                    Text("Ali DoH").tag("alidns")
                    Text("DNSPod").tag("dnspod")
                    Text("Cloudflare").tag("cloudflare")
                    Text("Google").tag("google")
                    Text("Custom").tag("custom")
                }
                .onChange(of: dnsProvider) { value in
                    Task { await model.updateConfig(["dns_provider": value]) }
                }
                Text("DNS-over-HTTPS service used to resolve domain-type remote hosts entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if dnsProvider == "custom" {
                    TextField("Custom DoH URL template", text: $dnsCustomURL)
                        .onSubmit(saveDNSTemplate)
                    Text("Must contain the {domain} placeholder, e.g. https://doh.example.com/resolve?name={domain}&type=A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !dnsCustomURL.isEmpty && !dnsCustomURL.contains("{domain}") {
                        Text("The template must contain the {domain} placeholder.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Toggle("Refresh Remote Hosts at Launch", isOn: $refreshOnLaunch)
                    .onChange(of: refreshOnLaunch) { value in
                        Task { await model.updateConfig(["refresh_remote_hosts_on_startup": value]) }
                    }
                Text("When enabled, every launch automatically refreshes all remote Hosts entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Remove Duplicate Records", isOn: $removeDuplicates)
                    .onChange(of: removeDuplicates) { value in
                        Task { await model.updateConfig(["remove_duplicate_records": value]) }
                    }
                Text("If a domain points to multiple IPs, only the first one will take effect, and the following ones will be converted into comments when hosts are applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show Title in Tray", isOn: $showTitleOnTray)
                    .onChange(of: showTitleOnTray) { value in
                        Task {
                            await model.updateConfig(["show_title_on_tray": value])
                            await model.reload()
                        }
                    }
                Toggle("Sync Child Items When Toggling Folders", isOn: $syncChildren)
                    .onChange(of: syncChildren) { value in
                        Task { await model.updateConfig(["multi_chose_folder_switch_all": value]) }
                    }
                Text("When enabled, toggling a folder also toggles its child items; child items inside single-choice folders are not toggled in bulk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Tray Icon Shortcut", isOn: $trayShortcut)
                    .onChange(of: trayShortcut) { value in
                        Task { await model.savePreference(["tray_mini_window": value]) }
                    }
                Text("When on, clicking the menu bar icon opens a small window. When off, it opens a menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Make SwitchHosts Better!") {
                Toggle("Yes, Submit Anonymized Usage Data", isOn: $sendUsageData)
                    .onChange(of: sendUsageData) { value in
                        Task { await model.updateConfig(["send_usage_data": value]) }
                    }
                Text("Would you like to help us improve SwitchHosts by periodically submitting anonymous usage data?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local HTTP API") {
                Toggle("Enable the local HTTP API", isOn: $httpOn)
                    .onChange(of: httpOn) { _ in applyHTTPAPI() }
                Toggle("Only accept connections from this Mac", isOn: $httpOnlyLocal)
                    .disabled(!httpOn)
                    .onChange(of: httpOnlyLocal) { _ in applyHTTPAPI() }
                TextField("Port", text: $httpPort)
                    .disabled(!httpOn)
                    .onSubmit(applyHTTPAPI)
                if !httpStatus.isEmpty {
                    Text(httpStatus).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Where Is My Data Stored?") {
                Text("Your data files are stored in:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(dataDir?.activeDir ?? "")
                    .textSelection(.enabled)
                    .lineLimit(2)
                if dataDir?.recoveryKind != nil {
                    Text("The recorded data folder is unavailable. Change it or reset to the default location.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Click to Open") {
                        if let path = dataDir?.activeDir {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                    Button("Change") { changeDataDir() }
                    Button("Reset") { resetDataDir() }
                        .disabled(!(dataDir?.canReset ?? false) && dataDir?.recoveryKind == nil)
                }
            }

            Section("Where Is My Hosts File?") {
                Text("Your hosts file is located at:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("/etc/hosts").textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    /// Pick a folder, show what it means, then switch and restart. Copying is optional.
    private func changeDataDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let plan = await model.planDataDir(url) else { return }
            if plan.isSameAsCurrent {
                let alert = NSAlert()
                alert.messageText = String(localized: "This folder is already your current data location.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runModal()
                return
            }
            let alert = NSAlert()
            if plan.isDefault {
                alert.messageText = String(localized: "Reset to the default data folder?")
                alert.informativeText = String(localized: "The app will restart. Data in the current folder is kept but no longer used.")
                alert.addButton(withTitle: String(localized: "Reset and Restart"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                if await model.resetDataDir() { AppRelaunch.restart() }
                return
            }
            alert.messageText = String(localized: "Change the data folder?")
            alert.informativeText = String(localized: "New data folder: \(plan.dataDir)")
            alert.addButton(withTitle: String(localized: "Copy Data and Restart"))
            alert.addButton(withTitle: String(localized: "Use Without Copying"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let response = alert.runModal()
            guard response != .alertThirdButtonReturn else { return }
            if await model.applyDataDir(url, copy: response == .alertFirstButtonReturn) {
                AppRelaunch.restart()
            }
        }
    }

    private func resetDataDir() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset to the default data folder?")
        alert.informativeText = String(localized: "The app will restart. Data in the current folder is kept but no longer used.")
        alert.addButton(withTitle: String(localized: "Reset and Restart"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if await model.resetDataDir() { AppRelaunch.restart() }
        }
    }

    private func load() async {
        let config = await model.loadConfig()
        dnsProvider = config["dns_provider"] as? String ?? "alidns"
        dnsCustomURL = config["dns_custom_url"] as? String ?? ""
        refreshOnLaunch = config["refresh_remote_hosts_on_startup"] as? Bool ?? false
        removeDuplicates = config["remove_duplicate_records"] as? Bool ?? false
        showTitleOnTray = config["show_title_on_tray"] as? Bool ?? false
        syncChildren = config["multi_chose_folder_switch_all"] as? Bool ?? false
        sendUsageData = config["send_usage_data"] as? Bool ?? false
        trayShortcut = config["tray_mini_window"] as? Bool ?? true
        httpOn = config["http_api_on"] as? Bool ?? false
        httpOnlyLocal = config["http_api_only_local"] as? Bool ?? true
        httpPort = String(config["http_api_port"] as? Int ?? 50761)
        loaded = true
        httpStatus = httpOn ? await model.configureHTTPAPI(on: true, port: Int(httpPort) ?? 50761, onlyLocal: httpOnlyLocal) : ""
        dataDir = await model.dataDirStatus()
    }

    /// Saves the DoH template when it contains the `{domain}` placeholder.
    private func saveDNSTemplate() {
        guard loaded, dnsCustomURL.isEmpty || dnsCustomURL.contains("{domain}") else { return }
        Task { await model.updateConfig(["dns_custom_url": dnsCustomURL]) }
    }

    /// Applies the listener change. Keys are saved by the core inside the same call.
    private func applyHTTPAPI() {
        guard loaded else { return }
        Task {
            let port = Int(httpPort.trimmingCharacters(in: .whitespaces)) ?? 0
            guard port >= 1 && port <= 65535 else {
                httpStatus = String(localized: "Port must be between 1 and 65535.")
                return
            }
            httpStatus = await model.configureHTTPAPI(on: httpOn, port: port, onlyLocal: httpOnlyLocal)
        }
    }
}
