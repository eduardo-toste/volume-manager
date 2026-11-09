import Testing

@testable import VolumeCore

@Suite("ProcessGrouping", .timeLimit(.minutes(1)))
struct ProcessGroupingTests {
  let info = FakeAppInfoProvider()

  private func group(_ processes: [AudioProcessInfo]) -> [AudioApp] {
    ProcessGrouping.group(processes, info: info)
  }

  @Test func chromeHelpersJoinTheMainApp() {
    let app = "/Applications/Google Chrome.app"
    info.setApp(app, name: "Google Chrome", bundleID: "com.google.Chrome")
    let helper =
      "\(app)/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/h"
    let result = group([
      AudioProcessInfo(
        pid: 10, bundleID: "com.google.Chrome",
        executablePath: "\(app)/Contents/MacOS/Google Chrome"),
      AudioProcessInfo(
        pid: 11, bundleID: "com.google.Chrome.helper", executablePath: helper, isRunningOutput: true
      ),
    ])
    #expect(result.count == 1)
    #expect(result[0].id == "com.google.Chrome")
    #expect(result[0].name == "Google Chrome")
    #expect(result[0].pids == [10, 11])
    #expect(result[0].isPlaying)
  }

  @Test func electronHelpersJoinTheMainApp() {
    let app = "/Applications/Discord.app"
    info.setApp(app, name: "Discord", bundleID: "com.hnc.Discord")
    let result = group([
      AudioProcessInfo(
        pid: 20,
        executablePath:
          "\(app)/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"
      ),
      AudioProcessInfo(pid: 21, executablePath: "\(app)/Contents/MacOS/Discord"),
    ])
    #expect(result.map(\.id) == ["com.hnc.Discord"])
    #expect(result[0].pids == [20, 21])
    #expect(!result[0].isPlaying)
  }

  @Test func webKitGPUResolvesThroughTheResponsibleProcess() {
    info.setPath("/Applications/Safari.app/Contents/MacOS/Safari", forPID: 100)
    info.setApp("/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari")
    let gpu =
      "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
    let result = group([
      AudioProcessInfo(
        pid: 200, bundleID: "com.apple.WebKit.GPU", executablePath: gpu, responsiblePID: 100,
        isRunningOutput: true)
    ])
    #expect(result.map(\.id) == ["com.apple.Safari"])
    #expect(result[0].name == "Safari")
    #expect(result[0].pids == [200])
  }

  @Test func pathIsLookedUpByPIDWhenNotProvided() {
    info.setPath("/Applications/Spotify.app/Contents/MacOS/Spotify", forPID: 7)
    info.setApp("/Applications/Spotify.app", name: "Spotify", bundleID: "com.spotify.client")
    let result = group([AudioProcessInfo(pid: 7)])
    #expect(result.map(\.id) == ["com.spotify.client"])
  }

  @Test func pathBeatsResponsibleProcessAndPrefix() {
    info.setPath("/Applications/Other.app/Contents/MacOS/Other", forPID: 1)
    info.setApp("/Applications/Mine.app", name: "Mine", bundleID: "com.mine.App")
    let result = group([
      AudioProcessInfo(
        pid: 2, bundleID: "com.third.Thing",
        executablePath: "/Applications/Mine.app/Contents/MacOS/m", responsiblePID: 1)
    ])
    #expect(result.map(\.id) == ["com.mine.App"])
  }

  @Test func fallsBackToTheBundleIDPrefix() {
    let result = group([
      AudioProcessInfo(pid: 5, bundleID: "com.vendor.Player.helper.renderer"),
      AudioProcessInfo(pid: 6, bundleID: "com.vendor.Player", isRunningOutput: true),
    ])
    #expect(result.count == 1)
    #expect(result[0].id == "com.vendor.Player")
    #expect(result[0].bundleID == "com.vendor.Player")
    #expect(result[0].name == "Player")
    #expect(result[0].pids == [5, 6])
  }

  @Test func shortBundleIDsAreKeptWhole() {
    let result = group([AudioProcessInfo(pid: 5, bundleID: "org.thing")])
    #expect(result.map(\.id) == ["org.thing"])
  }

  @Test func responsibleProcessThatIsUnknownFallsThrough() {
    let result = group([
      AudioProcessInfo(pid: 5, bundleID: "com.vendor.Player", responsiblePID: 99),
      AudioProcessInfo(pid: 6, bundleID: "com.vendor.Player", responsiblePID: 6),
      AudioProcessInfo(pid: 7, bundleID: "com.vendor.Player", responsiblePID: -1),
    ])
    #expect(result.map(\.id) == ["com.vendor.Player"])
    #expect(result[0].pids == [5, 6, 7])
  }

  @Test func appWithoutBundleIDUsesAPathKey() {
    info.setApp("/Applications/Odd.app", name: nil, bundleID: nil)
    let result = group([
      AudioProcessInfo(pid: 3, executablePath: "/Applications/Odd.app/Contents/MacOS/odd")
    ])
    #expect(result.map(\.id) == ["path:/Applications/Odd.app"])
    #expect(result[0].bundleID == nil)
    #expect(result[0].name == "Odd")
  }

  @Test func excludesOurselvesAndOurHelpers() {
    info.setApp(
      "/Applications/Volume Manager.app", name: "Volume Manager", bundleID: "com.volumemanager.app")
    let result = group([
      AudioProcessInfo(pid: 1, bundleID: "com.volumemanager.app"),
      AudioProcessInfo(pid: 2, bundleID: "com.volumemanager.app.helper"),
      AudioProcessInfo(
        pid: 3, executablePath: "/Applications/Volume Manager.app/Contents/MacOS/VolumeManager"),
      AudioProcessInfo(pid: 4, bundleID: "com.volumemanager.appX"),
    ])
    #expect(result.map(\.id) == ["com.volumemanager.appX"])
  }

  @Test func excludesSystemDaemonsWithoutAnApp() {
    let result = group([
      AudioProcessInfo(
        pid: 1, bundleID: "com.apple.audio.coreaudiod", executablePath: "/usr/sbin/coreaudiod"),
      AudioProcessInfo(
        pid: 2, bundleID: "com.apple.systemsounds",
        executablePath: "/System/Library/CoreServices/systemsoundserverd"),
      AudioProcessInfo(pid: 3),
      AudioProcessInfo(pid: 0, bundleID: "com.a.b"),
      AudioProcessInfo(pid: -4, bundleID: "com.a.b"),
    ])
    #expect(result.isEmpty)
  }

  @Test func systemAppsInsideSystemFoldersStayListed() {
    info.setApp("/System/Applications/Music.app", name: "Música", bundleID: "com.apple.Music")
    let result = group([
      AudioProcessInfo(
        pid: 9, executablePath: "/System/Applications/Music.app/Contents/MacOS/Music")
    ])
    #expect(result.map(\.name) == ["Música"])
  }

  @Test func traversalInThePathCannotFakeAnApp() {
    info.setApp("/tmp/Evil.app", name: "Evil", bundleID: "com.evil.app")
    let result = group([
      AudioProcessInfo(pid: 9, executablePath: "/Applications/../tmp/Evil.app/Contents/MacOS/x")
    ])
    #expect(result.map(\.id) == ["com.evil.app"])
  }

  @Test func namesAndBundleIDsAreSanitized() {
    info.setApp(
      "/Applications/X.app", name: "Good\u{202E}Name\u{0007}" + String(repeating: "z", count: 500),
      bundleID: "com.x.X")
    info.setApp("/Applications/Y.app", name: "   ", bundleID: "com.bad\u{202E}.id")
    let result = group([
      AudioProcessInfo(pid: 1, executablePath: "/Applications/X.app/Contents/MacOS/x"),
      AudioProcessInfo(pid: 2, executablePath: "/Applications/Y.app/Contents/MacOS/y"),
      AudioProcessInfo(pid: 3, bundleID: "com.bad\u{202E}.id"),
    ])
    let x = result.first { $0.id == "com.x.X" }
    #expect(x?.name.hasPrefix("GoodNamezzz") == true)
    #expect(x?.name.count == 200)
    let y = result.first { $0.id == "path:/Applications/Y.app" }
    #expect(y?.name == "Y")
    #expect(y?.bundleID == nil)
    #expect(result.count == 2)
  }

  @Test func outputIsStableAndSorted() {
    info.setApp("/Applications/B.app", name: "B", bundleID: "com.b.B")
    info.setApp("/Applications/A.app", name: "A", bundleID: "com.a.A")
    let processes = [
      AudioProcessInfo(pid: 2, executablePath: "/Applications/B.app/Contents/MacOS/b"),
      AudioProcessInfo(pid: 1, executablePath: "/Applications/A.app/Contents/MacOS/a"),
      AudioProcessInfo(pid: 3, executablePath: "/Applications/A.app/Contents/MacOS/a"),
    ]
    #expect(group(processes) == group(processes.reversed()))
    #expect(group(processes).map(\.id) == ["com.a.A", "com.b.B"])
  }

  @Test func validBundleIDRules() {
    #expect(ProcessGrouping.validBundleID("com.apple.Safari") == "com.apple.Safari")
    #expect(ProcessGrouping.validBundleID("a-b_c.D9") == "a-b_c.D9")
    #expect(ProcessGrouping.validBundleID("") == nil)
    #expect(ProcessGrouping.validBundleID(nil) == nil)
    #expect(ProcessGrouping.validBundleID("com.x y") == nil)
    #expect(ProcessGrouping.validBundleID("com.x/y") == nil)
    #expect(ProcessGrouping.validBundleID(String(repeating: "a", count: 201)) == nil)
    #expect(ProcessGrouping.bundlePrefix("com.vendor.App.helper") == "com.vendor.App")
  }
}
