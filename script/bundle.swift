#!/usr/bin/env swift
// Packages Eden into a Mac app. Build tooling only, and Swift like the rest.
//
//   swift script/bundle.swift            build/Eden.app, named "Eden Dev" (com.phantasyco.eden.dev)
//   swift script/bundle.swift --install  /Applications/Eden.app, the Eden you use day to day
//
// Dev builds get their own bundle ID. Otherwise every build/Eden.app, including
// the ones agents make in their worktrees, registers as "Eden", and macOS may
// open a stale one when you launch the app. The ID also gives dev builds their
// own settings and sessions, so testing never touches your real ones.

import Foundation

let install = CommandLine.arguments.dropFirst().contains("--install")
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let files = FileManager.default

/// Runs a tool from the repo's root; its output goes straight to the terminal.
/// Returns what it printed when `capture` is set.
@discardableResult
func run(_ tool: String, _ arguments: [String], capture: Bool = false) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool.hasPrefix("/") ? tool : "/usr/bin/env")
    process.arguments = tool.hasPrefix("/") ? arguments : [tool] + arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    if capture { process.standardOutput = output }
    do {
        try process.run()
    } catch {
        fail("Couldn't run \(tool): \(error.localizedDescription)")
    }
    let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(tool) \(arguments.joined(separator: " ")) failed") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// Build.
run("swift", ["build", "-c", "release", "--package-path", "App"])
let binary = URL(fileURLWithPath: run("swift", ["build", "-c", "release", "--package-path", "App", "--show-bin-path"], capture: true))
    .appendingPathComponent("Eden")

// The icon, drawn once by make_icon.swift if it isn't there yet.
let icon = root.appendingPathComponent("App/Packaging/AppIcon.icns")
if !files.fileExists(atPath: icon.path) {
    run("swift", ["script/make_icon.swift", "build/AppIcon.iconset"])
    run("/usr/bin/iconutil", ["-c", "icns", "build/AppIcon.iconset", "-o", icon.path])
}

// Assemble.
let (name, identifier) = install ? ("Eden", "com.phantasyco.eden") : ("Eden Dev", "com.phantasyco.eden.dev")
let app = install
    ? files.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Eden.app")
    : root.appendingPathComponent("build/Eden.app")
let contents = app.appendingPathComponent("Contents")
do {
    try? files.removeItem(at: app)
    try files.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try files.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try files.copyItem(at: binary, to: contents.appendingPathComponent("MacOS/Eden"))
    try files.copyItem(at: icon, to: contents.appendingPathComponent("Resources/AppIcon.icns"))

    let plist = root.appendingPathComponent("Config/Info.plist")
    var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any] ?? [:]
    info["CFBundleIdentifier"] = identifier
    info["CFBundleName"] = name
    info["CFBundleDisplayName"] = name
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
} catch {
    fail("Couldn't assemble \(app.path): \(error.localizedDescription)")
}
run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])

guard install else {
    print("Built \(app.path) (Eden Dev)")
    exit(0)
}

// Install over the Eden in /Applications and tell Launch Services about it.
let installed = URL(fileURLWithPath: "/Applications/Eden.app")
do {
    try? files.removeItem(at: installed)
    try files.moveItem(at: app, to: installed)
} catch {
    fail("Couldn't install to /Applications: \(error.localizedDescription)")
}
run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", installed.path])
print("Installed /Applications/Eden.app")
let running = Process()
running.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
running.arguments = ["-fq", "^/Applications/Eden.app/"]
try? running.run()
running.waitUntilExit()
if running.terminationStatus == 0 { print("Eden is running. Quit and reopen it to use this build.") }
