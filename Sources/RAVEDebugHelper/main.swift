/*
 rave-debug - pair this Mac with an app that offers debug access, and reach it

 The Mac half of RAVEDebugAccess. DebugTrace's `debugtrace-mcp` runs it: it
 is dependency-free Python and can't do the pairing's key agreement or
 TLS-PSK, so this tool pairs, and then carries its plain HTTP to the app over
 the paired channel.
 */

#if os(macOS)
import Foundation
import RAVEDebugAccess

let usage = """
usage: rave-debug pair [--host <address or name>] [--port <n>] [--name <this computer's name>] [--json]
       rave-debug list [--json]
       rave-debug proxy <app> [--host <address or name>] [--port <n>]
       rave-debug forget <app>

Pairs this computer with an app whose debug access is on, and carries debug
requests to it over an encrypted channel only the two of them can read.

  pair    Open the app's pairing screen on the device first (in Apparition:
          Settings > Developer > Pair a Computer). This finds the app, shows
          six digits to compare with the device, and stores the pairing once
          you tap Allow there. --host is for a device Bonjour can't find
          (another network, Tailscale): its address or tailnet name.
  list    The apps this computer is paired with.
  proxy   Listens on 127.0.0.1 and forwards each HTTP request to the app.
          Prints one line of JSON, {"port": N, "token": "..."}: send the
          token as `Authorization: Bearer`. Runs until its input closes.
  forget  Removes a pairing from this computer. Remove this computer in the
          app as well (its Settings list the paired computers).

<app> is an id from `list`, the beginning of one, or the app's name.
Pairings are kept in ~/.local/state/debugtrace/paired, readable by you only:
each holds the key to debug that app, so treat them like SSH keys.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rave-debug: \(message)\n".utf8))
    exit(1)
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

@MainActor func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

let json = flag("--json")
let host = option("--host")
let port = option("--port").map { value -> UInt16 in
    guard let port = UInt16(value), port > 0 else { fail("--port takes a port number") }
    return port
}
let computerName = option("--name") ?? Host.current().localizedName ?? "A Mac"
let apps = RAVEDebugPairedApps()
/// The running proxy, held for the life of the process: its listener answers only while it exists.
@MainActor enum Running {
    static var proxy: RAVEDebugProxy?
}

@MainActor func resolve(_ reference: String?) -> RAVEDebugPairedApp {
    guard let reference else { fail("which app? `rave-debug list` shows the paired ones") }
    guard let app = apps.app(reference) else {
        fail("no paired app matches '\(reference)' (or more than one does); `rave-debug list` shows them")
    }
    return app
}

switch arguments.first {
case nil, "-h", "--help", "help":
    print(usage)
case "list":
    let all = apps.all()
    if json {
        let data = (try? JSONSerialization.data(withJSONObject: all.map(\.summary), options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else if all.isEmpty {
        print("not paired with any app; open the app's pairing screen and run `rave-debug pair`")
    } else {
        for app in all {
            print("\(app.hostID)  \(app.name)\(app.host.map { "  (\($0))" } ?? "")")
        }
    }
case "forget":
    let app = resolve(arguments.dropFirst().first)
    guard apps.remove(app.hostID) else { fail("could not remove \(app.name)'s pairing from \(apps.directory.path)") }
    print("forgot \(app.name). Remove this computer in the app too: it lists it until then.")
case "pair":
    Task { @MainActor in
        let pairing = RAVEDebugPairing(apps: apps, computerName: computerName, host: host, port: port)
        let paired = await pairing.run { event in
            switch event {
            case .searching:
                if json { emit(["event": "searching"]) } else {
                    print(host.map { "Reaching \($0)…" } ?? "Looking for an app waiting to be paired…")
                }
            case .code(let code):
                if json { emit(["event": "code", "code": code]) } else {
                    print("\n    \(code)\n\nCompare this with the code on the device. If they match, tap Allow there.")
                }
            case .paired(let app):
                if json { emit(["event": "paired", "app": app.summary]) } else {
                    print("Paired with \(app.name). Its debug tools are now in `apps`.")
                }
            case .failed(let reason):
                if json { emit(["event": "failed", "reason": reason]) } else {
                    FileHandle.standardError.write(Data("rave-debug: \(reason)\n".utf8))
                }
            }
        }
        exit(paired == nil ? 1 : 0)
    }
    dispatchMain()
case "proxy":
    let app = resolve(arguments.dropFirst().first)
    Task { @MainActor in
        do {
            let proxy = try RAVEDebugProxy(app: app, apps: apps, host: host, port: port)
            Running.proxy = proxy
            let (port, token) = try await proxy.start()
            emit(["port": Int(port), "token": token, "app": app.summary])
            // Whoever started this owns it: when their end of the pipe closes, stop.
            Thread.detachNewThread {
                while readLine(strippingNewline: false) != nil {}
                exit(0)
            }
        } catch {
            fail("could not start the proxy: \(error)")
        }
    }
    dispatchMain()
default:
    fail("unknown command '\(arguments[0])'; `rave-debug --help` lists them")
}
#else
print("rave-debug runs on macOS only")
#endif
