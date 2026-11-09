import Testing

@testable import VolumeCore

@Suite("AppPath", .timeLimit(.minutes(1)))
struct AppPathTests {
  @Test func canonicalizesDotsAndSlashes() {
    #expect(
      AppPath.canonicalize("/Applications//Foo.app/./Contents/../Contents/MacOS/Foo")
        == "/Applications/Foo.app/Contents/MacOS/Foo")
    #expect(AppPath.canonicalize("/../../x") == "/x")
    #expect(AppPath.canonicalize("/") == "/")
  }

  @Test func rejectsRelativeControlAndOversizedPaths() {
    #expect(AppPath.canonicalize("Applications/Foo.app") == nil)
    #expect(AppPath.canonicalize("") == nil)
    #expect(AppPath.canonicalize("/Applications/Foo\u{0000}.app") == nil)
    #expect(AppPath.canonicalize("/a\n/b") == nil)
    #expect(AppPath.canonicalize("/" + String(repeating: "a", count: 2000)) == nil)
  }

  @Test func rejectsC1ControlsAndFormatCharacters() {
    #expect(AppPath.canonicalize("/Applications/Foo\u{0080}.app") == nil)
    #expect(AppPath.canonicalize("/Applications/Foo\u{009B}31m.app") == nil)  // CSI
    #expect(AppPath.canonicalize("/Applications/Foo\u{009F}.app") == nil)
    #expect(AppPath.canonicalize("/Applications/Foo\u{202E}ppa.app") == nil)  // bidi override
    #expect(AppPath.canonicalize("/Applications/Foo\u{200B}.app") == nil)  // zero width space
    #expect(AppPath.canonicalize("/Applications/Foo\u{2066}.app") == nil)  // bidi isolate
    #expect(AppPath.canonicalize("/Applications/Foo\u{FEFF}.app") == nil)
    #expect(AppPath.canonicalize("/Applications/\u{007F}Foo.app") == nil)
    #expect(AppPath.outermostAppPath(in: "/Applications/Fo\u{202E}o.app/Contents/MacOS/x") == nil)
  }

  @Test func acceptsOrdinaryNonAsciiPaths() {
    #expect(AppPath.canonicalize("/Applications/Música ✓.app") == "/Applications/Música ✓.app")
    #expect(AppPath.canonicalize("/Applications/日本語.app") == "/Applications/日本語.app")
    #expect(AppPath.canonicalize("/Applications/\u{00A0}x") != nil)  // U+00A0 is not C1
  }

  @Test func findsOutermostApp() {
    let chrome =
      "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework"
      + "/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    #expect(AppPath.outermostAppPath(in: chrome) == "/Applications/Google Chrome.app")
  }

  @Test func resolvesParentComponentsBeforeLookingForTheApp() {
    #expect(
      AppPath.outermostAppPath(in: "/Applications/../tmp/Evil.app/Contents/MacOS/x")
        == "/tmp/Evil.app")
    #expect(
      AppPath.outermostAppPath(in: "/Applications/Real.app/../Fake.app/Contents/MacOS/x")
        == "/Applications/Fake.app")
  }

  @Test func ignoresPathsWithoutAnAppBundle() {
    #expect(AppPath.outermostAppPath(in: "/usr/sbin/coreaudiod") == nil)
    #expect(AppPath.outermostAppPath(in: "/Applications/Foo.app") == nil)
    #expect(AppPath.outermostAppPath(in: "/Applications/.app/Contents/x") == nil)
    #expect(AppPath.outermostAppPath(in: "relative/Foo.app/Contents/x") == nil)
  }

  @Test func recognizesSystemPaths() {
    #expect(AppPath.isSystemPath("/System/Library/CoreServices/x"))
    #expect(AppPath.isSystemPath("/usr/sbin/coreaudiod"))
    #expect(!AppPath.isSystemPath("/Applications/Foo.app"))
    #expect(!AppPath.isSystemPath("/Users/me/usr/x"))
  }
}
