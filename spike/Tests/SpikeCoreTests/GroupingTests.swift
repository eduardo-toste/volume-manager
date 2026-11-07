import Testing

@testable import SpikeCore

@Suite struct GroupingTests {
    @Test func plainAppExecutable() {
        #expect(
            AppGrouping.outermostAppPath(in: "/Applications/Spotify.app/Contents/MacOS/Spotify")
                == "/Applications/Spotify.app")
    }

    @Test func nestedHelperResolvesToOutermostApp() {
        let helper =
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(AppGrouping.outermostAppPath(in: helper) == "/Applications/Google Chrome.app")
    }

    @Test func electronHelper() {
        let p = "/Applications/Discord.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper"
        #expect(AppGrouping.outermostAppPath(in: p) == "/Applications/Discord.app")
    }

    @Test func nonAppPathsAreRejected() {
        #expect(AppGrouping.outermostAppPath(in: "/usr/sbin/coreaudiod") == nil)
        #expect(AppGrouping.outermostAppPath(in: "/System/Library/Foo.app/NotContents/x") == nil)
        #expect(AppGrouping.outermostAppPath(in: "relative/Foo.app/Contents/x") == nil)
        #expect(AppGrouping.outermostAppPath(in: "/.app/Contents/x") == nil)
        #expect(AppGrouping.outermostAppPath(in: "") == nil)
    }

    @Test func resolutionOrder() {
        let viaPath = AppGrouping.resolve(
            executablePath: "/Applications/A.app/Contents/MacOS/A",
            responsiblePath: "/Applications/B.app/Contents/MacOS/B", bundleID: "com.x.y.z")
        #expect(viaPath.owner == .app(path: "/Applications/A.app"))
        #expect(viaPath.method == .executablePath)

        let viaResp = AppGrouping.resolve(
            executablePath: "/System/Library/Frameworks/WebKit.framework/x",
            responsiblePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            bundleID: "com.apple.WebKit.GPU")
        #expect(viaResp.owner == .app(path: "/Applications/Safari.app"))
        #expect(viaResp.method == .responsibleProcess)

        let viaPrefix = AppGrouping.resolve(
            executablePath: nil, responsiblePath: nil, bundleID: "com.vendor.App.helper.Renderer")
        #expect(viaPrefix.owner == .bundlePrefix("com.vendor.App"))

        let none = AppGrouping.resolve(executablePath: "/usr/sbin/coreaudiod", responsiblePath: nil, bundleID: nil)
        #expect(none.owner == .none)
    }

    @Test func sanitizeTruncatesAndStripsControls() {
        let long = String(repeating: "a", count: 500)
        #expect(Sanitize.text(long).count == 200)
        #expect(Sanitize.text("a\u{1B}[31mb\n") == "a?[31mb?")
    }
}

@Suite struct GainTests {
    @Test func perceptualCurve() {
        #expect(Gain.perceptual(0) == 0)
        #expect(Gain.perceptual(1) == 1)
        #expect(Gain.perceptual(0.5) == 0.25)
        #expect(Gain.perceptual(-3) == 0)
        #expect(Gain.perceptual(7) == 1)
        #expect(Gain.perceptual(.nan) == 1)
    }

    @Test func rampReachesTargetInAboutTwentyMs() {
        let step = Gain.rampStep(sampleRate: 48_000)
        var g: Float = 1
        var frames = 0
        while g > 0 {
            g = Gain.next(current: g, target: 0, step: step)
            frames += 1
        }
        #expect(frames >= 955 && frames <= 965)
        #expect(Gain.next(current: 0.5, target: 0.5, step: step) == 0.5)
    }
}
