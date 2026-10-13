import Foundation
import AVFoundation
import Accelerate

/// Считает пики для отрисовки waveform и отдаёт длительность файла.
/// Работает в фоне, вызывается через async/await.
///
/// Три вещи, от которых зависит скорость и стабильность:
///  1. расчёты идут на одной последовательной очереди — параллельные чтения
///     нескольких файлов только конкурируют за диск;
///  2. устаревший запрос прерывается на ближайшем блоке: если пользователь уже
///     выбрал другой трек, дочитывать предыдущий файл незачем;
///  3. пик считается по блоку через vDSP, а не по каждому кадру.
enum WaveformGenerator {

    struct WaveformData {
        var peaks: [Float] = []
        var duration: TimeInterval = 0
        /// true, если расчёт прерван как устаревший (результат неполный).
        var isCancelled = false
    }

    static let targetPeakCount = 900

    /// Последовательная очередь: одновременно считается не больше одного файла.
    private static let queue = DispatchQueue(label: "WaveformGenerator.queue", qos: .utility)

    /// ID запроса, который нужен прямо сейчас. Всё остальное считается устаревшим.
    private static let lock = NSLock()
    private static var currentRequestID: UUID?

    /// Объявляет запрос актуальным, отменяя предыдущие.
    static func makeCurrent(_ requestID: UUID) {
        lock.lock()
        currentRequestID = requestID
        lock.unlock()
    }

    private static func isStale(_ requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentRequestID != requestID
    }

    /// Полный расчёт пиков. `requestID` — кто запросил; при смене запроса
    /// расчёт прекращается и возвращается пустой результат.
    static func load(for track: Track, requestID: UUID) async -> WaveformData {
        makeCurrent(requestID)
        let path = track.path
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: compute(path: path, requestID: requestID))
            }
        }
    }

    /// Только длительность. Заголовок файла читается без разбора всех сэмплов,
    /// поэтому для сотни добавленных файлов это мгновенно.
    static func duration(of track: Track) async -> TimeInterval {
        let path = track.path
        return await withCheckedContinuation { continuation in
            queue.async {
                let url = URL(fileURLWithPath: path)
                guard let file = try? AVAudioFile(forReading: url) else {
                    continuation.resume(returning: 0)
                    return
                }
                let rate = file.processingFormat.sampleRate
                guard file.length > 0, rate > 0 else {
                    continuation.resume(returning: 0)
                    return
                }
                continuation.resume(returning: Double(file.length) / rate)
            }
        }
    }

    private static func compute(path: String, requestID: UUID) -> WaveformData {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            return WaveformData()
        }

        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, format.sampleRate > 0, format.channelCount > 0 else {
            return WaveformData()
        }

        let duration = Double(totalFrames) / format.sampleRate
        let framesPerPeak = max(1, Int(totalFrames) / targetPeakCount)

        // Буфер крупнее прежнего: меньше обращений к диску.
        let bufferSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
            return WaveformData(peaks: [], duration: duration)
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(targetPeakCount + 2)

        var framesInCurrentPeak = 0
        var currentPeak: Float = 0
        var remaining = totalFrames
        let channelCount = Int(format.channelCount)

        while remaining > 0 {
            if isStale(requestID) {
                return WaveformData(isCancelled: true)
            }

            let toRead = AVAudioFrameCount(min(Int64(bufferSize), remaining))
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }

            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { break }

            guard let channels = buffer.floatChannelData else { break }

            var offset = 0
            while offset < framesRead {
                let take = min(framesPerPeak - framesInCurrentPeak, framesRead - offset)
                var blockPeak: Float = 0

                for channel in 0..<channelCount {
                    var channelPeak: Float = 0
                    vDSP_maxmgv(channels[channel] + offset, 1, &channelPeak, vDSP_Length(take))
                    blockPeak = max(blockPeak, channelPeak)
                }

                currentPeak = max(currentPeak, blockPeak)
                framesInCurrentPeak += take
                offset += take

                if framesInCurrentPeak >= framesPerPeak {
                    peaks.append(currentPeak)
                    currentPeak = 0
                    framesInCurrentPeak = 0
                }
            }

            remaining -= Int64(framesRead)
        }

        if framesInCurrentPeak > 0 {
            peaks.append(currentPeak)
        }

        // Нормализация: тихие треки должны читаться на графике так же, как громкие.
        if let maxPeak = peaks.max(), maxPeak > 0.0001 {
            var scale = 1 / maxPeak
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(peaks.count))
            for index in peaks.indices where peaks[index] > 1 {
                peaks[index] = 1
            }
        }

        return WaveformData(peaks: peaks, duration: duration)
    }
}
