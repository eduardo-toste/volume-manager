import Testing

@testable import VolumeCore

@Suite("TextSanitizer", .timeLimit(.minutes(1)))
struct TextSanitizerTests {
  @Test func keepsPlainText() {
    #expect(TextSanitizer.clean("Spotify") == "Spotify")
    #expect(TextSanitizer.clean("Música ♫ 日本語") == "Música ♫ 日本語")
  }

  @Test func limitsLengthTo200Characters() {
    let long = String(repeating: "a", count: 5000)
    #expect(TextSanitizer.clean(long).count == 200)
    #expect(TextSanitizer.clean(long, limit: 5).count == 5)
    #expect(TextSanitizer.clean("abc", limit: 0).isEmpty)
  }

  @Test func boundsBytesForHugeGraphemeClusters() {
    let zalgo = "a" + String(repeating: "\u{0301}", count: 3000)
    #expect(TextSanitizer.clean(zalgo).utf8.count <= 800)
  }

  @Test func removesC0AndC1Controls() {
    #expect(TextSanitizer.clean("a\u{0000}b\u{0007}c\u{007F}d\u{0085}e\u{009F}f") == "abcdef")
  }

  @Test func removesBidiOverridesAndIsolates() {
    let hostile =
      "evil\u{202E}fdp.exe\u{202A}\u{202B}\u{202C}\u{202D}\u{2066}\u{2067}\u{2068}\u{2069}"
    #expect(TextSanitizer.clean(hostile) == "evilfdp.exe")
  }

  @Test func removesZeroWidthAndByteOrderMark() {
    #expect(
      TextSanitizer.clean("a\u{200B}b\u{200E}c\u{200F}d\u{FEFF}e") == "abcde")
    #expect(TextSanitizer.clean("a\u{2060}b\u{061C}c") == "abc")
  }

  @Test func normalizesWhitespace() {
    #expect(TextSanitizer.clean("  a \t\n b\u{00A0}\u{00A0}c\u{2028}d  ") == "a b c d")
    #expect(TextSanitizer.clean(" \t\n ").isEmpty)
  }

  @Test func neverInterpretsMarkupOrUrls() {
    let text = "<b>bold</b> https://x.test/%41 [link](javascript:1) \\(x) %@"
    #expect(TextSanitizer.clean(text) == text)
  }

  @Test func hugeInputIsBounded() {
    let huge = String(repeating: "x", count: 5_000_000)
    #expect(TextSanitizer.clean(huge).count == 200)
  }

  @Test func joinersSurviveOnlyBetweenVisibleCharacters() {
    let family = "👨\u{200D}👩\u{200D}👧"
    #expect(TextSanitizer.clean(family) == family)
    #expect(TextSanitizer.clean("a\u{200C}b") == "a\u{200C}b")
    #expect(TextSanitizer.clean("\u{200D}a") == "a")
    #expect(TextSanitizer.clean("a\u{200D}") == "a")
    #expect(TextSanitizer.clean("a \u{200D} b") == "a b")
    #expect(TextSanitizer.clean("a\u{200D}\u{200D}\u{200C}b") == "a\u{200D}b")
    #expect(TextSanitizer.clean("a\u{200D}\u{202E}b") == "a\u{200D}b")
    #expect(TextSanitizer.clean(String(repeating: "a\u{200D}", count: 300)).count <= 200)
  }
}
