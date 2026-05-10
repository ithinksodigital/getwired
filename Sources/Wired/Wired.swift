import AppKit
import Darwin
import Foundation
import IOKit
import ServiceManagement
import SystemConfiguration
import UserNotifications

@main
struct EthernetStatusMenuBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let networkInspector = EthernetNetworkInspector()
    private var refreshTimer: Timer?
    private var isMenuOpen = false
    private let launchAtLoginDefaultsKey = "launchAtLoginEnabled"
    private let launchAtLoginConsentKey = "launchAtLoginConsentAccepted"
    private let showIPInMenuBarDefaultsKey = "showIPInMenuBar"
    private var notificationsAuthorized = false
    private var previousConnectionState: Bool?

    /// UserNotifications requires running as an .app bundle; crashes when run from .build/.../Wired
    private var canUseNotifications: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if canUseNotifications {
            // Request immediately so the app is registered in System Settings > Notifications (required for the app to appear there).
            // Small delay so the app is active; then requestAuthorization registers the app and may show the permission dialog.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.checkAndRequestNotificationPermission()
            }
            refreshNotificationAuthorizationState()
        }
        applyLaunchAtLoginPreference(enabled: launchAtLoginPreferenceEnabled, showErrors: false)
        refreshAll()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusOnly()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func refreshAll() {
        let snapshot = networkInspector.snapshot()
        processConnectionStateChange(with: snapshot)
        updateStatusIcon(with: snapshot)
        rebuildMenu(with: snapshot)
    }

    private func refreshStatusOnly() {
        let snapshot = networkInspector.snapshot()
        processConnectionStateChange(with: snapshot)
        updateStatusIcon(with: snapshot)
        if isMenuOpen {
            rebuildMenu(with: snapshot)
        }
    }

    private func updateStatusIcon(with snapshot: EthernetSnapshot) {
        guard let button = statusItem.button else { return }
        button.title = ""

        if snapshot.interfaces.isEmpty {
            setMonochromeStatusIcon(for: button, symbolName: "questionmark.circle", fallbackTitle: "ETH ?")
            return
        }

        if snapshot.hasConnectedEthernet {
            let interface = preferredInterface(from: snapshot)
            let interfaceName = interface?.bsdName ?? "ETH"
            let ip = interface?.ipv4.first ?? interface?.ipv6.first
            let titleText: String
            if showIPInMenuBar, let ip, !ip.isEmpty {
                titleText = "\(interfaceName) (\(ip))"
            } else {
                titleText = interfaceName
            }
            setMonochromeStatusIcon(
                for: button,
                symbolName: "rectangle.connected.to.line.below",
                fallbackTitle: "ETH ON"
            )
            button.title = titleText
            button.imagePosition = .imageLeft
            button.toolTip = "Ethernet connected (\(interfaceName))"
        } else {
            let sortedInterfaces = snapshot.interfaces.sorted(by: { $0.bsdName < $1.bsdName })
            let disconnectedTitle: String
            if sortedInterfaces.count == 1, let only = sortedInterfaces.first {
                disconnectedTitle = "\(only.bsdName) disconnected"
            } else {
                disconnectedTitle = "All disconnected (\(sortedInterfaces.count))"
            }
            setMonochromeStatusIcon(
                for: button,
                symbolName: "network.slash",
                fallbackTitle: "ETH OFF"
            )
            button.title = disconnectedTitle
            button.imagePosition = .imageLeft
            button.toolTip = "Ethernet disconnected: \(disconnectedTitle)"
        }
    }

    private func setMonochromeStatusIcon(for button: NSStatusBarButton, symbolName: String, fallbackTitle: String) {
        if let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ethernet Status") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let configuredIcon = icon.withSymbolConfiguration(config) ?? icon
            configuredIcon.isTemplate = true
            button.image = configuredIcon
            button.imagePosition = .imageOnly
            button.toolTip = fallbackTitle
        } else {
            button.image = nil
            button.title = fallbackTitle
            button.toolTip = fallbackTitle
        }
    }

    private func makeStatusDot(connected: Bool) -> NSImage {
        let size: CGFloat = 8
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let color = connected ? NSColor.systemGreen : NSColor.gray
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func rebuildMenu(with snapshot: EthernetSnapshot) {
        let menu = NSMenu()
        menu.delegate = self

        let overallStatus = snapshot.hasConnectedEthernet ? "Connected" : "Disconnected"
        let statusMenuItem = NSMenuItem(title: "Ethernet Status: \(overallStatus)", action: nil, keyEquivalent: "")
        statusMenuItem.image = makeStatusDot(connected: snapshot.hasConnectedEthernet)
        menu.addItem(statusMenuItem)

        if let primary = snapshot.primaryInterface {
            menu.addItem(NSMenuItem(title: "Default Route Interface: \(primary)", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Default Route Interface: None", action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())

        if snapshot.interfaces.isEmpty {
            menu.addItem(NSMenuItem(title: "No Ethernet interfaces found", action: nil, keyEquivalent: ""))
        } else {
            let sortedInterfaces = snapshot.interfaces.sorted(by: { $0.bsdName < $1.bsdName })
            let connectedInterfaces = sortedInterfaces.filter(\.isConnected)
            let disconnectedInterfaces = sortedInterfaces.filter { !$0.isConnected }

            for info in connectedInterfaces {
                menu.addItem(interfaceMenuItem(for: info))
            }

            if !disconnectedInterfaces.isEmpty {
                let disconnectedItem = NSMenuItem(
                    title: "Disconnected Interfaces (\(disconnectedInterfaces.count))",
                    action: nil,
                    keyEquivalent: ""
                )
                let disconnectedSubmenu = NSMenu()
                for info in disconnectedInterfaces {
                    disconnectedSubmenu.addItem(interfaceMenuItem(for: info))
                }
                disconnectedItem.submenu = disconnectedSubmenu
                menu.addItem(disconnectedItem)
            }
        }

        menu.addItem(.separator())
        let showIPItem = NSMenuItem(
            title: "Show IP in menu bar",
            action: #selector(toggleShowIPInMenuBar),
            keyEquivalent: ""
        )
        showIPItem.target = self
        showIPItem.state = showIPInMenuBar ? .on : .off
        menu.addItem(showIPItem)

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAtLoginActive ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        let networkPrefsItem = NSMenuItem(title: "Open Network Settings", action: #selector(openNetworkSettings), keyEquivalent: "")
        networkPrefsItem.target = self
        menu.addItem(networkPrefsItem)
        if canUseNotifications {
            let notifPrefsItem = NSMenuItem(title: "Open Notification Settings", action: #selector(openNotificationSettings), keyEquivalent: "")
            notifPrefsItem.target = self
            menu.addItem(notifPrefsItem)
        }

        menu.addItem(.separator())
        let webItem = NSMenuItem(title: "wired.withbyte.co", action: #selector(openWebsite), keyEquivalent: "")
        webItem.target = self
        menu.addItem(webItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        refreshNotificationAuthorizationState()
        rebuildMenu(with: networkInspector.snapshot())
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    @objc
    private func openWebsite() {
        guard let url = URL(string: "https://wired.withbyte.co") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func openNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.network") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func openNotificationSettings() {
        // Opens System Settings > Notifications so user can enable Wired
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func interfaceMenuItem(for info: EthernetInterfaceInfo) -> NSMenuItem {
        let tags: [String] = [
            info.isConnected ? "connected" : "disconnected",
            info.isActiveDefaultRoute ? "active route" : "standby"
        ]

        let title = "\(info.bsdName) (\(info.displayName)) • \(tags.joined(separator: ", "))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Status: \(info.isConnected ? "Connected" : "Disconnected")", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Link Active: \(info.linkIsActive == true ? "Yes" : (info.linkIsActive == false ? "No" : "Unknown"))", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Default Route: \(info.isActiveDefaultRoute ? "Yes" : "No")", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Vendor: \(info.vendor)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Model: \(info.model)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "MAC Address: \(info.macAddress)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "IPv4: \(info.ipv4.isEmpty ? "None" : info.ipv4.joined(separator: ", "))", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "IPv6: \(info.ipv6.isEmpty ? "None" : info.ipv6.joined(separator: ", "))", action: nil, keyEquivalent: ""))
        submenu.addItem(.separator())
        submenu.addItem(copyMenuItem(title: "Copy IPv4", value: info.ipv4.joined(separator: ", ")))
        submenu.addItem(copyMenuItem(title: "Copy IPv6", value: info.ipv6.joined(separator: ", ")))
        submenu.addItem(copyMenuItem(title: "Copy MAC", value: info.macAddress == "Unknown" ? "" : info.macAddress))
        submenu.addItem(.separator())
        submenu.addItem(pingMenuItem(title: "Ping gateway", hostKey: "gateway"))
        submenu.addItem(pingMenuItem(title: "Check reachability (8.8.8.8)", hostKey: "8.8.8.8"))
        item.submenu = submenu
        return item
    }

    private func pingMenuItem(title: String, hostKey: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runPingReachability(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = hostKey
        return item
    }

    @objc
    private func runPingReachability(_ sender: NSMenuItem) {
        guard let hostKey = sender.representedObject as? String else { return }
        let label = hostKey == "gateway" ? "Ping gateway" : "Check reachability (8.8.8.8)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target: String
            if hostKey == "gateway" {
                target = PingHelper.defaultGateway() ?? "8.8.8.8"
            } else {
                target = hostKey
            }
            let ok = PingHelper.ping(host: target, timeoutSeconds: 2)
            DispatchQueue.main.async {
                self?.showPingResult(label: label, host: target, success: ok)
            }
        }
    }

    private func showPingResult(label: String, host: String, success: Bool) {
        let result = success ? "OK" : "timeout"
        let body = "\(host): \(result)"
        if canUseNotifications && notificationsAuthorized {
            sendNotification(title: label, body: body)
        } else {
            let alert = NSAlert()
            alert.messageText = label
            alert.informativeText = body
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    private func copyMenuItem(title: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(copyValueToClipboard(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.isEnabled = !value.isEmpty
        return item
    }

    @objc
    private func copyValueToClipboard(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func processConnectionStateChange(with snapshot: EthernetSnapshot) {
        let currentState = snapshot.hasConnectedEthernet
        defer { previousConnectionState = currentState }

        guard let previousConnectionState, previousConnectionState != currentState else {
            return
        }

        let interface = preferredInterface(from: snapshot)
        let interfaceName = interface?.bsdName ?? "unknown interface"
        let display = interface?.displayName ?? "Ethernet"
        let title = currentState ? "Ethernet Connected" : "Ethernet Disconnected"
        let body: String
        if currentState {
            let ip = interface?.ipv4.first ?? interface?.ipv6.first ?? "no IP"
            body = "\(interfaceName) (\(display)) • IP: \(ip)"
        } else {
            body = "\(interfaceName) (\(display))"
        }
        sendNotification(title: title, body: body)
    }

    private func preferredInterface(from snapshot: EthernetSnapshot) -> EthernetInterfaceInfo? {
        if let primary = snapshot.primaryInterface,
           let primaryInterface = snapshot.interfaces.first(where: { $0.bsdName == primary }) {
            return primaryInterface
        }

        return snapshot.interfaces.first(where: { $0.isConnected }) ?? snapshot.interfaces.first
    }

    private var launchAtLoginPreferenceEnabled: Bool {
        UserDefaults.standard.bool(forKey: launchAtLoginDefaultsKey)
    }

    private var showIPInMenuBar: Bool {
        get { UserDefaults.standard.bool(forKey: showIPInMenuBarDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showIPInMenuBarDefaultsKey) }
    }

    private var isLaunchAtLoginActive: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return launchAtLoginPreferenceEnabled
    }

    @objc
    private func toggleShowIPInMenuBar() {
        showIPInMenuBar = !showIPInMenuBar
        refreshAll()
    }

    @objc
    private func toggleLaunchAtLogin() {
        if isLaunchAtLoginActive {
            applyLaunchAtLoginPreference(enabled: false, showErrors: true)
            refreshAll()
            return
        }
        if !UserDefaults.standard.bool(forKey: launchAtLoginConsentKey) {
            guard presentLaunchAtLoginConsentAlert() else {
                refreshAll()
                return
            }
            UserDefaults.standard.set(true, forKey: launchAtLoginConsentKey)
        }
        applyLaunchAtLoginPreference(enabled: true, showErrors: true)
        refreshAll()
    }

    /// One-time explanation before the first attempt to enable login-item registration (`SMAppService`).
    private func presentLaunchAtLoginConsentAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Launch at Login"
        alert.informativeText = "Wired can start automatically when you log in to this Mac. You can turn this off anytime from this menu, or in System Settings → General → Login Items."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func applyLaunchAtLoginPreference(enabled: Bool, showErrors: Bool) {
        UserDefaults.standard.set(enabled, forKey: launchAtLoginDefaultsKey)

        guard #available(macOS 13.0, *) else { return }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            if showErrors {
                sendNotification(
                    title: "Launch at Login Error",
                    body: "Could not update login setting. Open as bundled .app to enable."
                )
            }
        }
    }

    private func checkAndRequestNotificationPermission() {
        guard canUseNotifications else { return }
        // Must call requestAuthorization at least once so the app appears in System Settings > Notifications.
        // If the user already decided, the system won't show the dialog again, just returns current status.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsAuthorized = granted
            }
        }
    }

    private func refreshNotificationAuthorizationState() {
        guard canUseNotifications else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = (settings.authorizationStatus == .authorized)
            DispatchQueue.main.async {
                self?.notificationsAuthorized = allowed
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        guard canUseNotifications else { return }
        func performSend() {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "eth-status-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        if notificationsAuthorized {
            performSend()
            return
        }
        // Re-check in case permission was just granted (async callback not yet run)
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = (settings.authorizationStatus == .authorized)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "eth-status-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            if allowed {
                UNUserNotificationCenter.current().add(request)
            }
            Task { @MainActor in
                if allowed { self?.notificationsAuthorized = true }
            }
        }
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}


struct EthernetSnapshot {
    let interfaces: [EthernetInterfaceInfo]
    let primaryInterface: String?

    var hasConnectedEthernet: Bool {
        interfaces.contains(where: { $0.isConnected })
    }
}

struct EthernetInterfaceInfo {
    let bsdName: String
    let displayName: String
    let isUp: Bool
    let isRunning: Bool
    let linkIsActive: Bool?
    let isActiveDefaultRoute: Bool
    let vendor: String
    let model: String
    let macAddress: String
    let ipv4: [String]
    let ipv6: [String]

    var isConnected: Bool {
        if let linkIsActive {
            return linkIsActive
        }
        return isUp && isRunning && (!ipv4.isEmpty || !ipv6.isEmpty)
    }
}

final class EthernetNetworkInspector {
    func snapshot() -> EthernetSnapshot {
        let primary = resolvePrimaryInterface()
        let byNameState = collectInterfaceState()
        let ethernetInterfaces = discoverEthernetInterfaces()
        let linkStatus = collectLinkStatus(for: ethernetInterfaces.map(\.bsdName))

        let interfaces: [EthernetInterfaceInfo] = ethernetInterfaces.map { descriptor in
            let state = byNameState[descriptor.bsdName] ?? InterfaceState()
            let hardware = resolveHardwareInfo(forBSDName: descriptor.bsdName)

            return EthernetInterfaceInfo(
                bsdName: descriptor.bsdName,
                displayName: descriptor.displayName,
                isUp: state.isUp,
                isRunning: state.isRunning,
                linkIsActive: linkStatus[descriptor.bsdName],
                isActiveDefaultRoute: descriptor.bsdName == primary,
                vendor: hardware.vendor,
                model: hardware.model,
                macAddress: hardware.macAddress ?? state.macAddress ?? "Unknown",
                ipv4: state.ipv4.sorted(),
                ipv6: state.ipv6.sorted()
            )
        }

        return EthernetSnapshot(interfaces: interfaces, primaryInterface: primary)
    }

    private func discoverEthernetInterfaces() -> [InterfaceDescriptor] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return []
        }

        return interfaces.compactMap { iface in
            guard
                let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                let type = SCNetworkInterfaceGetInterfaceType(iface),
                CFStringCompare(type, kSCNetworkInterfaceTypeEthernet, []) == .compareEqualTo
            else {
                return nil
            }

            let displayName = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? "Ethernet"
            return InterfaceDescriptor(bsdName: bsd, displayName: displayName)
        }
    }

    private func resolvePrimaryInterface() -> String? {
        if
            let ipv4State = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
            let primary = ipv4State["PrimaryInterface"] as? String {
            return primary
        }

        if
            let ipv6State = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv6" as CFString) as? [String: Any],
            let primary = ipv6State["PrimaryInterface"] as? String {
            return primary
        }

        return nil
    }

    private func collectLinkStatus(for bsdNames: [String]) -> [String: Bool] {
        var result: [String: Bool] = [:]

        for name in bsdNames {
            let key = "State:/Network/Interface/\(name)/Link" as CFString
            guard let linkState = SCDynamicStoreCopyValue(nil, key) as? [String: Any] else {
                continue
            }

            if let active = linkState["Active"] as? Bool {
                result[name] = active
                continue
            }

            if let active = linkState["Active"] as? NSNumber {
                result[name] = active.boolValue
            }
        }

        return result
    }

    private func collectInterfaceState() -> [String: InterfaceState] {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let head = ifaddrPointer else {
            return [:]
        }
        defer { freeifaddrs(ifaddrPointer) }

        var stateByInterface: [String: InterfaceState] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = head

        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let namePtr = entry.ifa_name else { continue }

            let name = String(cString: namePtr)
            guard let addrPtr = entry.ifa_addr else { continue }

            var state = stateByInterface[name] ?? InterfaceState()
            state.isUp = state.isUp || ((Int32(entry.ifa_flags) & IFF_UP) != 0)
            state.isRunning = state.isRunning || ((Int32(entry.ifa_flags) & IFF_RUNNING) != 0)

            switch Int32(addrPtr.pointee.sa_family) {
            case AF_INET:
                if let host = numericHost(from: addrPtr) {
                    state.ipv4.insert(host)
                }
            case AF_INET6:
                if let host = numericHost(from: addrPtr) {
                    state.ipv6.insert(host.replacingOccurrences(of: "%\(name)", with: ""))
                }
            case AF_LINK:
                if state.macAddress == nil {
                    state.macAddress = macAddress(fromLinkSockAddr: addrPtr)
                }
            default:
                break
            }

            stateByInterface[name] = state
        }

        return stateByInterface
    }

    private func numericHost(from sockaddrPtr: UnsafePointer<sockaddr>) -> String? {
        var storage = sockaddr_storage()
        memcpy(&storage, sockaddrPtr, Int(sockaddrPtr.pointee.sa_len))
        let storageLength = socklen_t(storage.ss_len)

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &storage) { storagePtr in
            storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getnameinfo(
                    rebound,
                    storageLength,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }

        guard result == 0 else { return nil }
        let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func macAddress(fromLinkSockAddr sockaddrPtr: UnsafePointer<sockaddr>) -> String? {
        withUnsafePointer(to: sockaddrPtr.pointee) { pointer in
            pointer.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr in
                let dl = dlPtr.pointee
                let hwLen = Int(dl.sdl_alen)
                let nameLen = Int(dl.sdl_nlen)
                guard hwLen > 0 else { return nil }

                return withUnsafePointer(to: dlPtr.pointee.sdl_data) { dataPtr in
                    let base = UnsafeRawPointer(dataPtr)
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: nameLen)
                    let octets = (0..<hwLen).map { base[$0] }
                    return octets.map { String(format: "%02X", $0) }.joined(separator: ":")
                }
            }
        }
    }

    private func resolveHardwareInfo(forBSDName bsdName: String) -> InterfaceHardwareInfo {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            return InterfaceHardwareInfo(vendor: "Unknown", model: "Unknown", macAddress: nil)
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return InterfaceHardwareInfo(vendor: "Unknown", model: "Unknown", macAddress: nil)
        }
        defer { IOObjectRelease(service) }

        var controller: io_registry_entry_t = 0
        let parentResult = IORegistryEntryGetParentEntry(service, kIOServicePlane, &controller)
        let provider = parentResult == KERN_SUCCESS ? controller : service

        let vendorName = registryString(for: provider, key: "vendor-name")
            ?? registryHexIdentifier(for: provider, key: "vendor-id")
            ?? "Unknown"

        let modelName = registryString(for: provider, key: "model")
            ?? registryString(for: provider, key: "IOName")
            ?? "Unknown"

        let mac = registryMACAddress(for: service) ?? registryMACAddress(for: provider)
        if controller != 0 {
            IOObjectRelease(controller)
        }
        return InterfaceHardwareInfo(vendor: vendorName, model: modelName, macAddress: mac)
    }

    private func registryString(for service: io_registry_entry_t, key: String) -> String? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = unmanaged.takeRetainedValue()

        if let stringValue = value as? String {
            return stringValue
        }

        if let dataValue = value as? Data {
            let cleaned = dataValue.prefix { $0 != 0 }
            guard !cleaned.isEmpty else { return nil }
            return String(decoding: cleaned, as: UTF8.self)
        }

        return nil
    }

    private func registryHexIdentifier(for service: io_registry_entry_t, key: String) -> String? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = unmanaged.takeRetainedValue()

        if let number = value as? NSNumber {
            return String(format: "0x%04X", number.uint16Value)
        }

        if let data = value as? Data, data.count >= 2 {
            let idValue = data.withUnsafeBytes { bytes -> UInt16 in
                guard let base = bytes.baseAddress else { return 0 }
                return base.assumingMemoryBound(to: UInt16.self).pointee
            }
            return String(format: "0x%04X", UInt16(littleEndian: idValue))
        }

        return nil
    }

    private func registryMACAddress(for service: io_registry_entry_t) -> String? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(service, "IOMACAddress" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = unmanaged.takeRetainedValue()
        guard let data = value as? Data, data.count >= 6 else {
            return nil
        }
        let octets = data.prefix(6).map { String(format: "%02X", $0) }
        return octets.joined(separator: ":")
    }
}

private struct InterfaceDescriptor {
    let bsdName: String
    let displayName: String
}

private struct InterfaceState {
    var isUp = false
    var isRunning = false
    var ipv4 = Set<String>()
    var ipv6 = Set<String>()
    var macAddress: String?
}

private struct InterfaceHardwareInfo {
    let vendor: String
    let model: String
    let macAddress: String?
}

enum PingHelper {
    static func defaultGateway() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("gateway:") {
                    let value = trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)
                    return value.isEmpty ? nil : String(value)
                }
            }
        } catch {}
        return nil
    }

    static func ping(host: String, timeoutSeconds: Int = 2) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-t", "\(timeoutSeconds)", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
