#!/usr/bin/env swift
import AppKit
import CoreServices
import Foundation

struct DeployFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DeployFailure(message: "\(executable) failed with status \(process.terminationStatus).")
    }
}

func checkBundle(_ url: URL, requireIcon: Bool = false) throws {
    let infoURL = url.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: infoURL),
          info["CFBundleIdentifier"] as? String == "com.xoba.fb.app" else {
        throw DeployFailure(message: "Expected an fb app bundle at \(url.path); no replacement was made.")
    }
    if requireIcon {
        let declaredIcon = info["CFBundleIconFile"] as? String
        let iconURL = url.appendingPathComponent("Contents/Resources/AppIcon.icns")
        guard info["CFBundleIconName"] as? String == "AppIcon",
              declaredIcon == "AppIcon" || declaredIcon == "AppIcon.icns",
              let icon = NSImage(contentsOf: iconURL), icon.isValid else {
            throw DeployFailure(message: "The new fb bundle must declare a readable AppIcon.icns; refusing to install an iconless build.")
        }
    }
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: deploy-app.swift SOURCE.app DESTINATION.app\n", stderr)
    exit(1)
}

let fileManager = FileManager.default
let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let installDirectory = destination.deletingLastPathComponent()
let stageDirectory = installDirectory.appendingPathComponent(".fb-deploy-\(UUID().uuidString)")
let stagedApp = stageDirectory.appendingPathComponent("fb.app")
let previousApp = stageDirectory.appendingPathComponent("previous-fb.app")
var keepStaging = false

do {
    try checkBundle(source, requireIcon: true)
    try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destination.path) {
        let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw DeployFailure(message: "Refusing to replace a symbolic link: \(destination.path)")
        }
        try checkBundle(destination)
    }
    try fileManager.createDirectory(at: stageDirectory, withIntermediateDirectories: false)
    defer {
        if !keepStaging { try? fileManager.removeItem(at: stageDirectory) }
    }

    // ditto preserves the bundle's metadata and nested code signatures.
    try run("/usr/bin/ditto", [source.path, stagedApp.path])
    try checkBundle(stagedApp, requireIcon: true)
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])

    // Match the installed path, so a Debug copy or open panel elsewhere is not
    // interrupted. NSRunningApplication termination is a normal app quit.
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.xoba.fb.app")
        .filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath() }
    for app in running where !app.isTerminated {
        guard app.terminate() else {
            throw DeployFailure(message: "Installed fb declined to quit; the existing installation was preserved.")
        }
    }
    let quitDeadline = Date().addingTimeInterval(10)
    while running.contains(where: { !$0.isTerminated }) && Date() < quitDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard running.allSatisfy({ $0.isTerminated }) else {
        throw DeployFailure(message: "Installed fb has not quit; the existing installation was preserved.")
    }

    var movedPrevious = false
    var installedNew = false
    do {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: previousApp)
            movedPrevious = true
        }
        try fileManager.moveItem(at: stagedApp, to: destination)
        installedNew = true
        try checkBundle(destination, requireIcon: true)
        // ditto preserves the old outer bundle timestamp. Refresh it and force
        // Launch Services to reread this exact installed bundle, including its
        // icon, even when a development build reused the same bundle version.
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        let registrationStatus = LSRegisterURL(destination as CFURL, true)
        guard registrationStatus == noErr else {
            throw DeployFailure(message: "Launch Services could not register the installed app (\(registrationStatus)).")
        }
    } catch {
        let installationError = error
        do {
            if installedNew { try fileManager.removeItem(at: destination) }
            if movedPrevious { try fileManager.moveItem(at: previousApp, to: destination) }
        } catch {
            keepStaging = true
            throw DeployFailure(message: "Install failed and restoration needs attention. Previous app retained at \(previousApp.path). Restoration error: \(error.localizedDescription)")
        }
        if !running.isEmpty { try? run("/usr/bin/open", [destination.path]) }
        throw installationError
    }

    print("Installed: \(destination.path)")
    if !running.isEmpty {
        try run("/usr/bin/open", [destination.path])
        print("Reopened installed fb.")
    }
} catch {
    fputs("Deploy failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
