import AVFoundation
import CallKit
import Combine
import UIKit

/// Reads Listen Together problems aloud (addendum 3, decision 8; guidance B).
@MainActor
protocol ListenTogetherSpeaking: AnyObject {
  /// Speaks `text` when "Speak error messages" is on, VoiceOver is not running and no call is
  /// connected (all checked now, at speak time). The same `key` is never queued twice.
  func speak(_ text: String, key: String)
}

/// The parts of AVSpeechSynthesizer the speaker uses. Test seam.
protocol ListenTogetherSpeechSynthesizing: AnyObject {
  func speak(_ utterance: AVSpeechUtterance)
  @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: ListenTogetherSpeechSynthesizing {}

/// One retained synthesizer for the app. Each utterance uses the person's Spoken Content voice and
/// rate (`prefersAssistiveTechnologySettings`; voice, rate, pitch and volume are never set), is never
/// sent into a call, and runs inside a background task so a locked phone finishes the sentence.
@MainActor
final class ListenTogetherSpeaker: NSObject, ListenTogetherSpeaking {
  static let shared = ListenTogetherSpeaker()

  /// Settings → Listen Together → "Speak error messages". Per device, off by default.
  static let settingKey = "listenTogetherSpeakErrors"
  /// "Hear a Sample" starts this long after the tap, so VoiceOver finishes reading the button first.
  static let sampleDelay: Duration = .milliseconds(500)
  static let sampleKey = "sample"

  private let synthesizer: ListenTogetherSpeechSynthesizing
  private let defaults: UserDefaults
  private let appSystem: ListenTogetherAppSystem
  /// Test seams.
  var isVoiceOverRunning: @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning }
  var isOnCall: @MainActor () -> Bool
  var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = { delay, action in
    Task { @MainActor in
      try? await Task.sleep(for: delay)
      action()
    }
  }

  private struct InFlight {
    /// Retained, so its identity can't be reused while the entry exists (code M3).
    let utterance: AVSpeechUtterance
    let key: String
    let backgroundTask: ListenTogetherBackgroundTask
  }

  /// Utterances queued or being spoken, by identity. An entry also goes when its background time runs
  /// out, so a sentence that never reports back can't block its key for good.
  private var inFlight: [ObjectIdentifier: InFlight] = [:]
  private var sampleGeneration = 0
  private let callObserver: CXCallObserver?
  private var voiceOverObservation: AnyCancellable?

  init(
    synthesizer: ListenTogetherSpeechSynthesizing? = nil,
    defaults: UserDefaults = .standard,
    appSystem: ListenTogetherAppSystem? = nil,
    observesSystem: Bool = true
  ) {
    let system = synthesizer ?? Self.makeSynthesizer()
    self.synthesizer = system
    self.defaults = defaults
    self.appSystem = appSystem ?? UIKitListenTogetherAppSystem()
    let callObserver = observesSystem ? CXCallObserver() : nil
    self.callObserver = callObserver
    self.isOnCall = { callObserver?.calls.contains { $0.hasConnected && !$0.hasEnded } ?? false }
    super.init()
    (system as? AVSpeechSynthesizer)?.delegate = self
    guard observesSystem else { return }
    voiceOverObservation = NotificationCenter.default
      .publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.voiceOverStatusChanged(isRunning: UIAccessibility.isVoiceOverRunning) }
      }
  }

  private static func makeSynthesizer() -> AVSpeechSynthesizer {
    let synthesizer = AVSpeechSynthesizer()
    // The system speech session ducks the book the way VoiceOver does (check on device); the book
    // keeps playing.
    synthesizer.usesApplicationAudioSession = false
    // Never spoken into a phone or FaceTime call.
    synthesizer.mixToTelephonyUplink = false
    return synthesizer
  }

  var isEnabled: Bool { defaults.bool(forKey: Self.settingKey) }

  /// Pure gate for an error message (not the sample). Test seam.
  nonisolated static func shouldSpeak(isEnabled: Bool, isVoiceOverRunning: Bool, isOnCall: Bool) -> Bool {
    isEnabled && !isVoiceOverRunning && !isOnCall
  }

  func speak(_ text: String, key: String) {
    guard Self.shouldSpeak(isEnabled: isEnabled, isVoiceOverRunning: isVoiceOverRunning(), isOnCall: isOnCall())
    else { return }
    guard !inFlight.values.contains(where: { $0.key == key }) else { return }
    enqueue(text, key: key)
  }

  /// "Hear a Sample": spoken even while VoiceOver runs (the person asked for it). A second tap stops
  /// what is being said and starts again, so speech never stacks.
  func speakSample() {
    sampleGeneration += 1
    let generation = sampleGeneration
    stopAll(at: .immediate)
    schedule(Self.sampleDelay) { [weak self] in
      guard let self, self.sampleGeneration == generation else { return }
      self.enqueue("settings_listen_together_speak_sample_text".localized, key: Self.sampleKey)
    }
  }

  /// VoiceOver turned on: stop at the next word and drop the queue (VoiceOver users get the alert and
  /// announcement path). Turning off repeats nothing.
  func voiceOverStatusChanged(isRunning: Bool) {
    guard isRunning, !inFlight.isEmpty else { return }
    stopAll(at: .word)
  }

  /// An utterance finished or was cancelled: its background task ends.
  func utteranceEnded(_ utterance: AVSpeechUtterance) {
    inFlight.removeValue(forKey: ObjectIdentifier(utterance))?.backgroundTask.end()
  }

  /// How many utterances are queued or being spoken. Test seam.
  var queuedCount: Int { inFlight.count }

  private func enqueue(_ text: String, key: String) {
    let utterance = AVSpeechUtterance(string: text)
    // The person's Spoken Content voice and rate. Voice, rate, pitch and volume are left alone: any of
    // them would override that choice.
    utterance.prefersAssistiveTechnologySettings = true
    let id = ObjectIdentifier(utterance)
    let task = ListenTogetherBackgroundTask(system: appSystem, name: "Listen Together speech") { [weak self] in
      self?.inFlight.removeValue(forKey: id)
    }
    inFlight[id] = InFlight(utterance: utterance, key: key, backgroundTask: task)
    synthesizer.speak(utterance)
  }

  private func stopAll(at boundary: AVSpeechBoundary) {
    guard !inFlight.isEmpty else { return }
    synthesizer.stopSpeaking(at: boundary)
    // Cancelled utterances may not all report back: end their background tasks now.
    let ending = inFlight
    inFlight = [:]
    ending.values.forEach { $0.backgroundTask.end() }
  }
}

extension ListenTogetherSpeaker: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    ended(utterance)
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    ended(utterance)
  }

  private nonisolated func ended(_ utterance: AVSpeechUtterance) {
    nonisolated(unsafe) let utterance = utterance
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.utteranceEnded(utterance) }
    }
  }
}
