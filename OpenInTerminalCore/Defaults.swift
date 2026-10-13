//
//  Defaults.swift
//  OpenInTerminalCore
//
//  Created by Jianing Wang on 2019/4/21.
//  Copyright © 2019 Jianing Wang. All rights reserved.
//

import Foundation

/// Shared preferences for the full app and its Finder extension.
///
/// The legacy `group.wang.jianing.app.OpenInTerminal` suite cannot be shared
/// reliably by this unsandboxed app on macOS 27. Keep its identifier only for
/// migrating old preferences; the released app does not claim that entitlement.
///
/// The extension can already read `~/Library/Application Scripts/<its bundle id>`
/// (that is where its AppleScripts live). The unsandboxed app can write there
/// without an app group or a paid Developer ID, so both processes share this
/// plist. Lite apps keep `UserDefaults.standard`; they have no extension.
public final class DefaultsStore: NSObject {

    private let standardDefaults: UserDefaults?
    private let fileURL: URL?
    private var storage: [String: Any] = [:]
    private var loadedMtime: Date?
    private let lock = NSLock()

    fileprivate init(standardDefaults: UserDefaults) {
        self.standardDefaults = standardDefaults
        self.fileURL = nil
        super.init()
    }

    fileprivate init(fileURL: URL) {
        self.standardDefaults = nil
        self.fileURL = fileURL
        super.init()
        migrateLegacyFileIfNeeded()
        migrateLegacyGroupIfNeeded()
        lock.lock()
        reloadIfNeededLocked()
        lock.unlock()
    }

    static func resolve() -> DefaultsStore {
        let bundleID = Bundle.main.bundleIdentifier
        if bundleID == Constants.Id.OpenInTerminalLite || bundleID == Constants.Id.OpenInEditorLite {
            return DefaultsStore(standardDefaults: .standard)
        }
        return DefaultsStore(fileURL: sharedFileURL())
    }

    /// `~/Library/Application Scripts/<finder extension bundle id>/shared-defaults.plist`
    public static func sharedFileURL() -> URL {
        return realHomeDirectory()
            .appendingPathComponent("Library/Application Scripts", isDirectory: true)
            .appendingPathComponent(Constants.Id.FinderExtension, isDirectory: true)
            .appendingPathComponent("shared-defaults.plist")
    }

    public func synchronize() {
        guard standardDefaults == nil else {
            standardDefaults?.synchronize()
            return
        }
        lock.lock()
        saveLocked()
        lock.unlock()
    }

    public func removePersistentDomain(forName name: String) {
        if let standardDefaults = standardDefaults {
            standardDefaults.removePersistentDomain(forName: name)
            return
        }
        lock.lock()
        storage.removeAll()
        loadedMtime = nil
        if let fileURL = fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        lock.unlock()
    }

    public override func value(forUndefinedKey key: String) -> Any? {
        if let standardDefaults = standardDefaults {
            return standardDefaults.object(forKey: key)
        }
        lock.lock()
        reloadIfNeededLocked()
        let value = storage[key]
        lock.unlock()
        return value
    }

    public override func setValue(_ value: Any?, forUndefinedKey key: String) {
        setObject(value, forKey: key)
    }

    fileprivate func object(forKey key: String) -> Any? {
        if let standardDefaults = standardDefaults {
            return standardDefaults.object(forKey: key)
        }
        lock.lock()
        reloadIfNeededLocked()
        let value = storage[key]
        lock.unlock()
        return value
    }

    fileprivate func setObject(_ value: Any?, forKey key: String) {
        if let standardDefaults = standardDefaults {
            standardDefaults.set(value, forKey: key)
            return
        }
        willChangeValue(forKey: key)
        lock.lock()
        reloadIfNeededLocked()
        if let value = value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
        saveLocked()
        lock.unlock()
        didChangeValue(forKey: key)
    }

    private func migrateLegacyFileIfNeeded() {
        guard let fileURL = fileURL,
              !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let legacyURL = Self.realHomeDirectory()
            .appendingPathComponent("Library/Application Scripts", isDirectory: true)
            .appendingPathComponent("wang.jianing.app.OpenInTerminal.OpenInTerminalFinderExtension", isDirectory: true)
            .appendingPathComponent("shared-defaults.plist")
        guard let data = try? Data(contentsOf: legacyURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              plist is [String: Any] else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logw("Failed to migrate preferences: \(error.localizedDescription)")
        }
    }

    private func migrateLegacyGroupIfNeeded() {
        guard let fileURL = fileURL else { return }
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let suiteName = Constants.Id.Group
        guard let legacy = UserDefaults(suiteName: suiteName)?.persistentDomain(forName: suiteName),
              !legacy.isEmpty else {
            return
        }
        storage = legacy
        lock.lock()
        saveLocked()
        lock.unlock()
        logw("Migrated \(legacy.count) preferences from the legacy app group")
    }

    private func reloadIfNeededLocked() {
        guard let fileURL = fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let mtime = modificationDate(of: fileURL)
        if let loadedMtime = loadedMtime, let mtime = mtime, mtime <= loadedMtime {
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let raw = plist as? [String: Any] else {
            return
        }
        storage = raw.mapValues(decode)
        loadedMtime = mtime ?? Date()
    }

    private func saveLocked() {
        guard let fileURL = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoded = storage.mapValues(encode)
            let data = try PropertyListSerialization.data(fromPropertyList: encoded, format: .xml, options: 0)
            try data.write(to: fileURL, options: .atomic)
            loadedMtime = modificationDate(of: fileURL) ?? Date()
        } catch {
            logw("Failed to save preferences: \(error.localizedDescription)")
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Objects Cocoa bindings hand us (shortcut dictionaries) are property lists.
    /// Anything else is archived so a later launch can restore it.
    private func encode(_ value: Any) -> Any {
        if PropertyListSerialization.propertyList(value, isValidFor: .xml) {
            return value
        }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false) {
            return ["OITArchivedObject": data]
        }
        return String(describing: value)
    }

    private func decode(_ value: Any) -> Any {
        let wrapper = value as? [String: Any] ?? (value as? NSDictionary as? [String: Any])
        guard let data = wrapper?["OITArchivedObject"] as? Data,
              wrapper?.count == 1 else {
            return value
        }
        if let object = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) {
            return object
        }
        return value
    }

    private static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

public let Defaults: DefaultsStore = DefaultsStore.resolve()

public class DefaultsKeys {
    fileprivate init() {}
}

public class DefaultsKey<ValueType>: DefaultsKeys {
    let _key: String

    init(_ key: String) {
        self._key = key
    }
}

public extension DefaultsKeys {
    // Preferences - General
    static let firstSetup = DefaultsKey<Bool>("FirstSetup")
    static let launchAtLogin = DefaultsKey<Bool>("LaunchAtLogin")
    static let quickToggle = DefaultsKey<Bool>("QuickToggle")
    static let quickToggleType = DefaultsKey<String>("QuickToggleType")
    static let hideStatusItem = DefaultsKey<Bool>("HideStatusItem")
    static let hideContextMenuItems = DefaultsKey<Bool>("HideContextMenuItems")
    static let contextMenuUseSubmenu = DefaultsKey<Bool>("ContextMenuUseSubmenu")
    static let defaultTerminal = DefaultsKey<String>("DefaultTerminal")
    static let defaultEditor = DefaultsKey<String>("DefaultEditor")
    // Preferences - Custom
    static let terminalNewOption = DefaultsKey<String>("TerminalNewOption")
    static let iTermNewOption = DefaultsKey<String>("iTermNewOption")
    static let customMenuOptions = DefaultsKey<Data>("CustomMenuOptions")
    static let customMenuApplyToToolbar = DefaultsKey<Bool>("CustomMenuApplyToToolbar")
    static let customMenuApplyToContext = DefaultsKey<Bool>("CustomMenuApplyToContext")
    static let customMenuIconOption = DefaultsKey<String>("CustomMenuIconOption")
    static let pathEscapeOption = DefaultsKey<Bool>("PathEscapeOption")
    static let kittyCommand = DefaultsKey<String>("KittyCommand")
    static let onlyActivateShortcutsInFinder = DefaultsKey<Bool>("OnlyActivateShortcutsInFinder")
    static let neovimCommand = DefaultsKey<String>("NeovimCommand")
    static let gitkrakenCommand = DefaultsKey<String>("GitkrakenCommand")

    // for Lite
    static let liteDefaultTerminal = DefaultsKey<String>("LiteDefaultTerminal")
    static let liteDefaultEditor = DefaultsKey<String>("LiteDefaultEditor")
}

public extension DefaultsStore {
    subscript(key: DefaultsKey<String>) -> String? {
        get { return object(forKey: key._key) as? String }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<Bool>) -> Bool {
        get {
            if let number = object(forKey: key._key) as? NSNumber {
                return number.boolValue
            }
            return false
        }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<Int>) -> Int {
        get {
            if let number = object(forKey: key._key) as? NSNumber {
                return number.intValue
            }
            return 0
        }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<Float>) -> Float {
        get {
            if let number = object(forKey: key._key) as? NSNumber {
                return number.floatValue
            }
            return 0
        }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<Double>) -> Double {
        get {
            if let number = object(forKey: key._key) as? NSNumber {
                return number.doubleValue
            }
            return 0
        }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<URL>) -> URL? {
        get {
            guard let string = object(forKey: key._key) as? String else { return nil }
            return URL(string: string)
        }
        set { setObject(newValue?.absoluteString, forKey: key._key) }
    }
    subscript(key: DefaultsKey<Any>) -> Any? {
        get { return object(forKey: key._key) }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<[Any]>) -> [Any]? {
        get { return object(forKey: key._key) as? [Any] }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<Data>) -> Data? {
        get { return object(forKey: key._key) as? Data }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<[String: Any]>) -> [String: Any]? {
        get {
            if let dictionary = object(forKey: key._key) as? [String: Any] {
                return dictionary
            }
            return object(forKey: key._key) as? NSDictionary as? [String: Any]
        }
        set { setObject(newValue, forKey: key._key) }
    }
    subscript(key: DefaultsKey<[String]>) -> [String]? {
        get { return object(forKey: key._key) as? [String] }
        set { setObject(newValue, forKey: key._key) }
    }
}
