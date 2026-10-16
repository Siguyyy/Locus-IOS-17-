import AVFoundation
import Foundation

/// Plays near-silent audio so iOS keeps Locus runnable (and able to accept
/// TCP) while the user is in Settings › Developer Mode.
final class SilentAudioKeepAlive {
    private let queue = DispatchQueue(label: "com.chrismack.locus.audio-keepalive", qos: .utility)
    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?

    init() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.start()
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let resetObserver {
            NotificationCenter.default.removeObserver(resetObserver)
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .ended {
            start()
        }
    }

    private func startLocked() {
        if player?.isPlaying == true { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            // 0.1s of near-silence, looped.
            let url = try Self.writeSilentWAV()
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0.01
            p.prepareToPlay()
            guard p.play() else {
                NSLog("[Locus] silent audio keep-alive could not start playback")
                return
            }
            player = p
            NSLog("[Locus] silent audio keep-alive started")
        } catch {
            NSLog("[Locus] silent audio keep-alive failed: %@", error.localizedDescription)
        }
    }

    private func stopLocked() {
        NSLog("[Locus][Audio] keep-alive stop")
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func writeSilentWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locus-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate: Int = 8000
        let durationSamples = sampleRate / 10 // 0.1s
        var data = Data()

        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        let dataSize = UInt32(durationSamples * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(1) // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(dataSize)
        data.append(Data(count: Int(dataSize))) // zeros = silence

        try data.write(to: url, options: .atomic)
        return url
    }
}

