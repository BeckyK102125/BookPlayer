@testable import BookPlayer
import AVFoundation
import XCTest

/// Records utterances instead of speaking them.
final class FakeSynthesizer: ListenTogetherSpeechSynthesizing {
  var spoken: [AVSpeechUtterance] = []
  var stops: [AVSpeechBoundary] = []
  func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance) }
  func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
    stops.append(boundary)
    return true
  }
}

/// "Speak error messages" (addendum 3, decision 8; guidance B).
@MainActor
final class ListenTogetherSpeakerTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!
  private var synthesizer: FakeSynthesizer!
  private var system: FakeAppSystem!
  private var timers: ManualScheduler!
  private var voiceOver = false
  private var onCall = false

  override func setUp() async throws {
    suiteName = "ListenTogetherSpeakerTests-\(UUID())"
    defaults = UserDefaults(suiteName: suiteName)
    synthesizer = FakeSynthesizer()
    system = FakeAppSystem()
    timers = ManualScheduler()
    voiceOver = false
    onCall = false
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
  }

  private func makeSpeaker(enabled: Bool = true) -> ListenTogetherSpeaker {
    defaults.set(enabled, forKey: ListenTogetherSpeaker.settingKey)
    let speaker = ListenTogetherSpeaker(
      synthesizer: synthesizer, defaults: defaults, appSystem: system, observesSystem: false)
    speaker.isVoiceOverRunning = { [unowned self] in self.voiceOver }
    speaker.isOnCall = { [unowned self] in self.onCall }
    speaker.schedule = timers.schedule
    return speaker
  }

  func testOffByDefault() {
    let fresh = UserDefaults(suiteName: "ListenTogetherSpeakerTests-default-\(UUID())")!
    XCTAssertFalse(fresh.bool(forKey: ListenTogetherSpeaker.settingKey))
    XCTAssertEqual(ListenTogetherSpeaker.settingKey, "listenTogetherSpeakErrors")
  }

  func testGate() {
    XCTAssertTrue(ListenTogetherSpeaker.shouldSpeak(isEnabled: true, isVoiceOverRunning: false, isOnCall: false))
    XCTAssertFalse(ListenTogetherSpeaker.shouldSpeak(isEnabled: false, isVoiceOverRunning: false, isOnCall: false))
    XCTAssertFalse(ListenTogetherSpeaker.shouldSpeak(isEnabled: true, isVoiceOverRunning: true, isOnCall: false))
    XCTAssertFalse(ListenTogetherSpeaker.shouldSpeak(isEnabled: true, isVoiceOverRunning: false, isOnCall: true))
  }

  func testSpeaksWithThePersonsSpokenContentSettingsOnly() throws {
    let speaker = makeSpeaker()
    speaker.speak("The person sharing ended Listen Together.", key: "sharerEnded")
    let utterance = try XCTUnwrap(synthesizer.spoken.first)
    XCTAssertEqual(utterance.speechString, "The person sharing ended Listen Together.")
    XCTAssertTrue(utterance.prefersAssistiveTechnologySettings)
    XCTAssertNil(utterance.voice, "the voice is never set")
    XCTAssertEqual(utterance.rate, AVSpeechUtteranceDefaultSpeechRate, "the rate is never set")
    XCTAssertEqual(utterance.pitchMultiplier, 1, "the pitch is never set")
    XCTAssertEqual(utterance.volume, 1, "the volume is never set")
  }

  func testSilentWhenOffDuringVoiceOverAndDuringACall() {
    let off = makeSpeaker(enabled: false)
    off.speak("a", key: "a")
    XCTAssertTrue(synthesizer.spoken.isEmpty)

    let speaker = makeSpeaker()
    voiceOver = true
    speaker.speak("b", key: "b")
    XCTAssertTrue(synthesizer.spoken.isEmpty, "VoiceOver already reads it")
    voiceOver = false
    onCall = true
    speaker.speak("c", key: "c")
    XCTAssertTrue(synthesizer.spoken.isEmpty, "never over a call")
    onCall = false
    speaker.speak("d", key: "d")
    XCTAssertEqual(synthesizer.spoken.map(\.speechString), ["d"], "checked at speak time")
  }

  func testTheSameMessageIsNotQueuedTwice() throws {
    let speaker = makeSpeaker()
    speaker.speak("x", key: "retryingSend")
    speaker.speak("x", key: "retryingSend")
    XCTAssertEqual(synthesizer.spoken.count, 1)
    speaker.utteranceEnded(try XCTUnwrap(synthesizer.spoken.first))
    speaker.speak("x", key: "retryingSend")
    XCTAssertEqual(synthesizer.spoken.count, 2, "again once the first has finished")
  }

  func testEachUtteranceHasABackgroundTaskEndedOnFinishAndOnExpiry() throws {
    let speaker = makeSpeaker()
    speaker.speak("one", key: "one")
    speaker.speak("two", key: "two")
    XCTAssertEqual(system.begun.count, 2)
    speaker.utteranceEnded(try XCTUnwrap(synthesizer.spoken.first))
    XCTAssertEqual(system.ended, [system.begun[0]])
    system.expireAll()
    XCTAssertEqual(Set(system.ended), Set(system.begun))
    speaker.utteranceEnded(synthesizer.spoken[1])
    XCTAssertEqual(system.ended.count, 2, "never ended twice")
  }

  func testVoiceOverTurningOnStopsAndClearsTheQueue() {
    let speaker = makeSpeaker()
    speaker.speak("one", key: "one")
    speaker.speak("two", key: "two")
    speaker.voiceOverStatusChanged(isRunning: true)
    XCTAssertEqual(synthesizer.stops, [.word])
    XCTAssertEqual(speaker.queuedCount, 0)
    XCTAssertEqual(Set(system.ended), Set(system.begun), "background tasks end with it")
    speaker.voiceOverStatusChanged(isRunning: false)
    XCTAssertEqual(synthesizer.spoken.count, 2, "nothing is replayed when VoiceOver turns off")
  }

  func testSampleSpeaksEvenWithVoiceOverAfterAShortDelay() {
    let speaker = makeSpeaker()
    voiceOver = true
    speaker.speakSample()
    XCTAssertTrue(synthesizer.spoken.isEmpty, "VoiceOver finishes reading the button first")
    timers.advance(by: .milliseconds(500))
    XCTAssertEqual(synthesizer.spoken.map(\.speechString), ["This is how Listen Together problems are read aloud."])
    XCTAssertTrue(synthesizer.spoken[0].prefersAssistiveTechnologySettings)
  }

  func testASecondSampleTapRestartsInsteadOfStacking() {
    let speaker = makeSpeaker()
    speaker.speakSample()
    timers.advance(by: .milliseconds(500))
    speaker.speakSample()
    XCTAssertEqual(synthesizer.stops, [.immediate], "the first sample stops")
    speaker.speakSample()
    timers.advance(by: .milliseconds(500))
    XCTAssertEqual(synthesizer.spoken.count, 2, "one sample per restart, never stacked")
    XCTAssertEqual(speaker.queuedCount, 1)
  }

  func testAnUtteranceWhoseTimeRanOutNoLongerBlocksItsKey() {
    let speaker = makeSpeaker()
    speaker.speak("x", key: "sharerEnded")
    system.expireAll()
    XCTAssertEqual(speaker.queuedCount, 0, "removed on expiry (code M3)")
    speaker.speak("x", key: "sharerEnded")
    XCTAssertEqual(synthesizer.spoken.count, 2)
  }
}
