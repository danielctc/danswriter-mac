import AppKit

enum TypewriterSoundPolicy {
    static func shouldPlay(eventType: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard eventType == .keyDown else { return false }
        return !modifiers.contains(.command) && !modifiers.contains(.control) && !modifiers.contains(.function)
    }
}

/// A short original mechanical tick, cached once and reused while a small voice pool is available.
final class TypewriterSoundPlayer {
    static let shared = TypewriterSoundPlayer()
    private let lock = NSLock()
    private var sounds: [NSSound] = []
    private var lastPlayed = Date.distantPast

    private init() {}

    func playIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "WriteOn.typewriterSound") else { stop() ; return }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastPlayed) >= 0.022 else { return }
        lastPlayed = now
        if sounds.isEmpty, let data = Self.makeWaveData() { sounds = (0..<3).compactMap { _ in NSSound(data: data) } }
        guard let sound = sounds.first(where: { !$0.isPlaying }) ?? sounds.first else { return }
        sound.volume = 0.12
        sound.currentTime = 0
        sound.play()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        sounds.forEach { $0.stop() }
    }

    static func validWaveData() -> Data? { makeWaveData() }

    private static func makeSound() -> NSSound? {
        guard let data = makeWaveData() else { return nil }
        return NSSound(data: data)
    }

    private static func makeWaveData() -> Data? {
        let sampleRate = 22_050
        let count = 900
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let envelope = exp(-t * 1050)
            let fundamental = sin(2 * Double.pi * 1_470 * t)
            let overtone = sin(2 * Double.pi * 2_410 * t) * 0.27
            var sample = Int16(max(-1, min(1, (fundamental + overtone) * envelope * 0.52)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wave = Data("RIFF".utf8)
        wave.appendLE(UInt32(36 + pcm.count)); wave.append(contentsOf: "WAVEfmt ".utf8)
        wave.appendLE(UInt32(16)); wave.appendLE(UInt16(1)); wave.appendLE(UInt16(1))
        wave.appendLE(UInt32(sampleRate)); wave.appendLE(UInt32(sampleRate * 2)); wave.appendLE(UInt16(2)); wave.appendLE(UInt16(16))
        wave.append(contentsOf: "data".utf8); wave.appendLE(UInt32(pcm.count)); wave.append(pcm)
        return wave
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
