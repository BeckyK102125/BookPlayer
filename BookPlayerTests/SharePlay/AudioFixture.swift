import AVFoundation

enum AudioFixture {
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
