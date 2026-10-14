import AVFoundation
import XCTest

enum AudioFixture {
  enum WaitError: Error { case timedOut }

  /// Poll an observable asynchronous outcome, failing the test instead of silently timing out.
  /// Simulator audio startup can take 15 seconds; allow preparation to finish without weakening
  /// the readiness/playing condition or adding an unconditional sleep to every test.
  @MainActor
  static func waitUntil(timeout: TimeInterval = 30, player: AVPlayer? = nil,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else {
        let state = player.map {
          " (item status: \(String(describing: $0.currentItem?.status)), control: \($0.timeControlStatus), time: \($0.currentTime().seconds), error: \(String(describing: $0.currentItem?.error)))"
        } ?? ""
        XCTFail("Timed out waiting for audio preparation/playback\(state)", file: file, line: line)
        throw WaitError.timedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Writes `seconds` of a quiet 440 Hz tone as AAC in an .m4a file.
  static func makeM4A(seconds: Double, at url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(seconds * 44_100)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for i in 0..<Int(frames) { samples[i] = 0.1 * sinf(Float(i) * 2 * .pi * 440 / 44_100) }
    try file.write(from: buffer)
  }
}
