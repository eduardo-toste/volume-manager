import Foundation
import Testing

@testable import SpikeCore

// Additional QA tests (M0.5): hostile paths, sanitization, gain curve, ramp and the copy kernel model.

@Suite struct QAGroupingTests {
    @Test func nestedAppsResolveToOutermost() {
        let p = "/Applications/A.app/Contents/Frameworks/B.app/Contents/Frameworks/C.app/Contents/MacOS/c"
        #expect(AppGrouping.outermostAppPath(in: p) == "/Applications/A.app")
    }

    @Test func pathsWithoutAppOrContentsAreRejected() {
        for p in ["/", "//", "/usr/bin/afplay", "/Applications/Foo.app", "/Applications/Foo.app/", "/Foo.app/Contents2/x",
            "/Foo.app/contents/x", "/Foo.APP/Contents/x", "/Foo.app.bak/Contents/x", "/.app/Contents/x", "/a/.app/Contents/x"]
        {
            #expect(AppGrouping.outermostAppPath(in: p) == nil, "\(p)")
        }
    }

    @Test func appWithContentsAsLastComponentIsAccepted() {
        #expect(AppGrouping.outermostAppPath(in: "/Applications/Foo.app/Contents") == "/Applications/Foo.app")
    }

    @Test func doubleSlashesAreNormalizedInResult() {
        #expect(AppGrouping.outermostAppPath(in: "//Applications//Foo.app//Contents//MacOS/x") == "/Applications/Foo.app")
    }

    @Test func dotDotComponentsAreNotResolved() {
        // Documents current behavior: ".." is kept verbatim (no canonicalization). Result is still a string only
        // used for grouping/display; M2 must not use it to open files without canonicalizing.
        let r = AppGrouping.outermostAppPath(in: "/Applications/../tmp/Evil.app/Contents/MacOS/x")
        #expect(r == "/Applications/../tmp/Evil.app")
    }

    @Test func fakeContentsInsideNonAppDirectoryIsNotAnApp() {
        #expect(AppGrouping.outermostAppPath(in: "/tmp/Contents/Foo.app/x") == nil)
    }

    @Test func hugeAndWeirdStringsDoNotCrash() {
        let huge = "/" + String(repeating: "a/", count: 200_000) + "X.app/Contents/x"
        #expect(AppGrouping.outermostAppPath(in: huge)?.hasSuffix("X.app") == true)
        let manyApps = "/" + String(repeating: "A.app/", count: 50_000)
        #expect(AppGrouping.outermostAppPath(in: manyApps) == nil)
        #expect(AppGrouping.outermostAppPath(in: "/Ünï/日本語.app/Contents/MacOS/x") == "/Ünï/日本語.app")
        #expect(AppGrouping.outermostAppPath(in: "/a\u{0}b.app/Contents/x") == "/a\u{0}b.app")
        #expect(AppGrouping.outermostAppPath(in: "/\u{202E}pp.app/Contents/x") == "/\u{202E}pp.app")
    }

    @Test func bundlePrefixEdgeCases() {
        #expect(AppGrouping.fallbackBundlePrefix("") == nil)
        #expect(AppGrouping.fallbackBundlePrefix("com") == nil)
        #expect(AppGrouping.fallbackBundlePrefix("com.a") == nil)
        #expect(AppGrouping.fallbackBundlePrefix("..a..b..c..d") == "a.b.c")
        #expect(AppGrouping.fallbackBundlePrefix("com.a.b") == "com.a.b")
        #expect(AppGrouping.fallbackBundlePrefix("com.a.b.c.d") == "com.a.b")
        #expect(AppGrouping.fallbackBundlePrefix(String(repeating: "a.", count: 100_000)) == "a.a.a")
    }

    @Test func spoofedBundleIDNeverBeatsPath() {
        let r = AppGrouping.resolve(
            executablePath: "/Applications/Real.app/Contents/MacOS/x", responsiblePath: nil, bundleID: "com.apple.Safari")
        #expect(r.owner == .app(path: "/Applications/Real.app"))
        #expect(r.method == .executablePath)
    }

    @Test func allNilResolvesToNone() {
        let r = AppGrouping.resolve(executablePath: nil, responsiblePath: nil, bundleID: nil)
        #expect(r.owner == .none)
        #expect(r.method == .none)
    }
}

@Suite struct QASanitizeTests {
    @Test func stripsAllC0ControlsAndDEL() {
        for v in 0..<0x20 {
            let s = Sanitize.text("a" + String(UnicodeScalar(UInt8(v))) + "b")
            #expect(s == "a?b", "scalar \(v)")
        }
        #expect(Sanitize.text("a\u{7F}b") == "a?b")
    }

    @Test func emptyAndLimitBoundaries() {
        #expect(Sanitize.text("") == "")
        #expect(Sanitize.text("abc", limit: 0) == "")
        #expect(Sanitize.text("abc", limit: 3) == "abc")
        #expect(Sanitize.text("abcd", limit: 3) == "abc")
    }

    @Test func hugeInputIsBounded() {
        let big = String(repeating: "x", count: 5_000_000)
        #expect(Sanitize.text(big).count == 200)
        #expect(Sanitize.text(big, limit: 1024).count == 1024)
    }

    @Test func unicodeIsPreserved() {
        #expect(Sanitize.text("日本語 – Ünï 🎵") == "日本語 – Ünï 🎵")
    }

    @Test func c1ControlsAndBidiOverridesAreNotStripped() {
        // Documents a gap (recommendation for M2): C1 controls (0x80-0x9F), bidi overrides and zero-width
        // characters pass through the sanitizer unchanged.
        #expect(Sanitize.text("a\u{85}b") == "a\u{85}b")
        #expect(Sanitize.text("a\u{202E}b") == "a\u{202E}b")
        #expect(Sanitize.text("a\u{200B}b") == "a\u{200B}b")
    }
}

@Suite struct QAGainTests {
    @Test func curveEndpointsAndSquare() {
        #expect(Gain.perceptual(0) == 0)
        #expect(Gain.perceptual(1) == 1)
        #expect(Gain.perceptual(0.5) == 0.25)
    }

    @Test func curveIsMonotonicAndBounded() {
        var prev: Float = -1
        for i in 0...10_000 {
            let g = Gain.perceptual(Float(i) / 10_000)
            #expect(g >= prev)
            #expect(g >= 0 && g <= 1)
            prev = g
        }
    }

    @Test func outOfRangeAndNonFinite() {
        #expect(Gain.perceptual(-0.0001) == 0)
        #expect(Gain.perceptual(1.0001) == 1)
        #expect(Gain.perceptual(.infinity) == 1)
        #expect(Gain.perceptual(-.infinity) == 0)
        #expect(Gain.perceptual(.nan) == 1)
        #expect(Gain.perceptual(.greatestFiniteMagnitude) == 1)
        #expect(Gain.perceptual(-.greatestFiniteMagnitude) == 0)
        #expect(Gain.perceptual(.leastNonzeroMagnitude) >= 0)
    }

    @Test func rampStepForRealisticRates() {
        for rate in [8_000.0, 24_000, 44_100, 48_000, 96_000, 192_000] {
            let step = Gain.rampStep(sampleRate: rate)
            #expect(step > 0 && step.isFinite)
            #expect(step <= Float(1.0 / (rate * 0.020)) * 1.0001)
        }
    }

    @Test func rampStepDegenerateRatesStayUsable() {
        #expect(Gain.rampStep(sampleRate: 0) == 1)
        #expect(Gain.rampStep(sampleRate: -48_000) == 1)
        #expect(Gain.rampStep(sampleRate: 1) == 1)
    }

    @Test func rampDownAndUpHaveNoLargeStepsAndLandExactly() {
        for rate in [24_000.0, 48_000, 96_000] {
            let step = Gain.rampStep(sampleRate: rate)
            for (from, to) in [(Float(1), Float(0)), (0, 1), (1, 0.25), (0.25, 1), (0.3, 0.3)] {
                var g = from
                var maxDelta: Float = 0
                var frames = 0
                while g != to && frames < 1_000_000 {
                    let n = Gain.next(current: g, target: to, step: step)
                    maxDelta = max(maxDelta, abs(n - g))
                    g = n
                    frames += 1
                }
                #expect(g == to)
                #expect(maxDelta <= step * 1.0001)
                #expect(Double(frames) <= rate * 0.020 + 2)
            }
        }
    }

    @Test func nextNeverOvershoots() {
        let step = Gain.rampStep(sampleRate: 48_000)
        #expect(Gain.next(current: 0.9999, target: 1, step: step) <= 1)
        #expect(Gain.next(current: 0.0001, target: 0, step: step) >= 0)
        #expect(Gain.next(current: 0, target: 1, step: 5) == 1)
        #expect(Gain.next(current: 1, target: 0, step: 5) == 0)
    }

    @Test func retargetMidRampIsContinuous() {
        let step = Gain.rampStep(sampleRate: 48_000)
        var g: Float = 1
        for _ in 0..<300 { g = Gain.next(current: g, target: 0, step: step) }
        let before = g
        g = Gain.next(current: g, target: 1, step: step)
        #expect(abs(g - before) <= step * 1.0001)
    }
}

/// Model of the IOProc copy loop (`TapSession.tapIOProc` is private in the executable target and cannot be imported).
/// If the kernel stays inline in M2, extract it into SpikeCore/VolumeCore so these tests exercise the real code.
@Suite struct QAKernelModelTests {
    private func kernel(_ input: [Float], channels: Int, target: Float, start: Float, step: Float) -> (out: [Float], end: Float) {
        var out = [Float](repeating: 0, count: input.count)
        var g = start
        for f in 0..<(input.count / channels) {
            g = Gain.next(current: g, target: target, step: step)
            for c in 0..<channels { out[f * channels + c] = input[f * channels + c] * g }
        }
        return (out, g)
    }

    private func signal(_ n: Int) -> [Float] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<n).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
        } + [.leastNonzeroMagnitude, -0.0, 1, -1, .nan, 0.5]
    }

    @Test func unityGainIsBitExact() {
        let input = signal(4_000)
        let r = kernel(input, channels: 2, target: 1, start: 1, step: 0.001)
        for (a, b) in zip(input, r.out) { #expect(a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN)) }
    }

    @Test func constantGainScalesInput() {
        let input = signal(4_000)
        let g = Gain.perceptual(0.5)
        let r = kernel(input, channels: 2, target: g, start: g, step: 0.001)
        for (a, b) in zip(input, r.out) where !a.isNaN { #expect(b == a * g) }
    }

    @Test func zeroGainGivesSilence() {
        let input = signal(1_000).filter { $0.isFinite }
        let r = kernel(input, channels: 2, target: 0, start: 0, step: 0.001)
        #expect(r.out.allSatisfy { $0 == 0 })
    }

    @Test func rampIsSharedAcrossChannelsOfAFrame() {
        let input = [Float](repeating: 1, count: 2_000)
        let r = kernel(input, channels: 2, target: 0, start: 1, step: Gain.rampStep(sampleRate: 48_000))
        for f in 0..<1_000 { #expect(r.out[2 * f] == r.out[2 * f + 1]) }
        #expect(r.out[0] < 1 && r.end < 1)
    }
}
