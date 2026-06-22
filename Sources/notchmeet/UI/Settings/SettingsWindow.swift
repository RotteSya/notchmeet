import AppKit
import Combine
import SwiftUI

/// Owns the settings window and keeps the AppKit boundary deliberately small.
/// The SwiftUI hierarchy lives in focused files beside this controller.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let previousPolicy: NSApplication.ActivationPolicy
    private let store: ScriptStore
    private let nav = SettingsNav()

    var onKeysChanged: (() -> Void)?
    var onBuildBank: (() -> Void)?
    var onDeleteData: (() -> Void)?
    var onRerunOnboarding: (() -> Void)?

    init(store: ScriptStore) {
        self.store = store
        self.previousPolicy = NSApp.activationPolicy()
        super.init()
    }

    func show(section: SettingsSection? = nil) {
        if let section { nav.section = section }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            store: store,
            nav: nav,
            onKeysChanged: { [weak self] in self?.onKeysChanged?() },
            onBuildBank: { [weak self] in self?.onBuildBank?() },
            onDeleteData: { [weak self] in self?.onDeleteData?() },
            onRerunOnboarding: { [weak self] in self?.onRerunOnboarding?() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .fullSizeContentView, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = SettingsPalette.windowNSColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.animationBehavior = .documentWindow
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.delegate = self

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.layer?.backgroundColor = .clear
        window.contentView = hosting
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(previousPolicy)
        window = nil
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, scripts, keys, answer, privacy, about

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .scripts: "doc.text"
        case .keys: "key"
        case .answer: "sparkles"
        case .privacy: "lock"
        case .about: "info.circle"
        }
    }

    func title(_ strings: AppStrings) -> String {
        switch self {
        case .general: strings.secGeneral
        case .scripts: strings.secScripts
        case .keys: strings.secKeys
        case .answer: strings.secAnswer
        case .privacy: strings.secPrivacy
        case .about: strings.secAbout
        }
    }
}

final class SettingsNav: ObservableObject {
    @Published var section: SettingsSection = .general
}
