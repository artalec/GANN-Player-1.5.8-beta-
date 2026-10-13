import Foundation
import AVFoundation
import Combine

/// Аудиодвижок с поддержкой trim, seek, громкости, автоперехода на следующий трек.
///
/// Два независимых канала (A и B) для честного кроссфейда. У каждого канала своя
/// цепочка player → EQ → mainMixer. EQ реализует эффект High-cut (плавное закрытие верхов).
final class AudioEngine: ObservableObject {

    // MARK: - Публикуемое состояние

    @Published private(set) var isPlaying = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentTime: TimeInterval = 0

    // MARK: - Настройки и колбеки

    var settings = AppSettings()
    
    /// Вызывается при завершении трека (дошёл до trimEnd или до конца файла).
    /// AppModel решает: запустить следующий, зациклить, удалить.
    var onTrackFinished: (() -> Void)?

    // MARK: - Внутренние узлы

    private final class Channel {
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        var file: AVAudioFile?
        var generation = 0
        /// Формат, с которым канал подключён к движку: переподключаем только при его смене.
        var connectedFormat: AVAudioFormat?
        /// Проходит ли сигнал через EQ. Для многоканальных файлов EQ отключается,
        /// иначе AVAudioUnitEQ может уронить движок при подключении.
        var connectedViaEQ = true
    }

    private let engine = AVAudioEngine()
    private var channels: [Channel] = []
    private var activeIndex = 0
    
    /// Время начала воспроизводимого сегмента относительно файла (учитывает trimStart).
    private var activeFileOffset: TimeInterval = 0

    private var rampTimer: Timer?
    private var timeTimer: Timer?
    private var rampGeneration = 0

    /// Идёт плавное затухание (Esc) — завершение трека не должно запускать следующий.
    private var isFadingOut = false

    private let lowPassOpenFrequency: Float = 20000
    private let lowPassClosedFrequency: Float = 180
    private let rampStepsPerSecond: Double = 30

    // MARK: - Инициализация

    init() {
        channels = [Channel(), Channel()]

        for channel in channels {
            engine.attach(channel.player)
            engine.attach(channel.eq)

            let band = channel.eq.bands[0]
            band.filterType = .lowPass
            band.frequency = lowPassOpenFrequency
            band.bypass = true
            channel.eq.bypass = false

            // Единый формат графа: 44.1 кГц стерео. Файлы с другим форматом
            // приводятся к нему автоматически самим микшером (см. startSegment).
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            engine.connect(channel.player, to: channel.eq, format: format)
            engine.connect(channel.eq, to: engine.mainMixerNode, format: format)
            channel.connectedFormat = format
            channel.connectedViaEQ = true
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("DJPlayer: не удалось запустить аудиодвижок — \(error.localizedDescription)")
        }
        applyVolume()
    }

    // MARK: - Основное управление

    /// Запускает трек. `from` — позиция относительно trimStart, с которой начинается
    /// воспроизведение (например, точка, выбранная на waveform до запуска трека).
    func play(track: Track, from position: TimeInterval = 0) {
        guard track.exists else {
            NSLog("DJPlayer: файл не найден — \(track.path)")
            return
        }

        // Проверяем файл ДО остановки текущего воспроизведения: если он не
        // открывается, играющий трек продолжит звучать, а не оборвётся.
        guard Self.canOpen(track.url) else {
            NSLog("DJPlayer: файл не открывается — \(track.path)")
            return
        }

        let start = max(0, min(position, max(0, track.effectiveDuration)))

        if isPlaying && currentTrack != nil {
            if settings.highCutEnabled {
                transitionWithHighCut(to: track, from: start)
            } else if settings.crossfadeEnabled {
                transitionWithCrossfade(to: track, from: start)
            } else {
                hardSwitch(to: track, position: start)
            }
        } else {
            hardSwitch(to: track, position: start)
        }
    }

    /// Плавное затухание играющего трека за `duration` секунд и полная остановка (Esc).
    /// Затухают все звучащие каналы: во время crossfade и high-cut играют два канала,
    /// и если погасить только активный, второй остался бы звучать.
    func fadeOutAndStop(duration: TimeInterval = 1.0) {
        let sounding = channels.filter { $0.file != nil }

        guard !sounding.isEmpty else {
            stop()
            return
        }

        cancelRamp()
        isFadingOut = true

        let startVolumes = sounding.map { max(0, min($0.player.volume, 1)) }
        let total = max(0.05, duration)
        let steps = max(2, Int(total * rampStepsPerSecond))
        let interval = total / Double(steps)

        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)
            for (index, channel) in sounding.enumerated() {
                channel.player.volume = startVolumes[index] * (1 - progress)
            }

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil
                // stop() сбросит isFadingOut и вернёт громкость на место
                self.stop()
            }
        }
    }

    /// Focus Fade: плавно убирает громкость и ставит воспроизведение на паузу.
    /// Позиция сохраняется, поэтому возврат к плееру продолжится с того же места.
    /// Возвращает true, если пауза действительно была выполнена.
    @discardableResult
    func fadeOutPause(duration: TimeInterval = 1.5) -> Bool {
        // Во время перехода играют два канала, и прерывать его нельзя:
        // незавершённый переход оставил бы второй трек звучать.
        guard isPlaying, !isTransitioning, currentTrack != nil else { return false }

        let sounding = channels.filter { $0.file != nil }
        guard !sounding.isEmpty else { return false }

        cancelRamp()
        isFadingOut = true

        let startVolumes = sounding.map { max(0, min($0.player.volume, 1)) }
        let total = max(0.05, duration)
        let steps = max(2, Int(total * rampStepsPerSecond))
        let interval = total / Double(steps)

        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)
            for (index, channel) in sounding.enumerated() {
                channel.player.volume = startVolumes[index] * (1 - progress)
            }

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil

                // Пауза, а не остановка: позиция в файле сохраняется.
                for channel in sounding {
                    channel.player.pause()
                    // Громкость возвращаем сразу — при возобновлении снова уйдём с нуля.
                    channel.player.volume = 1.0
                }
                self.stopTimeTimer()
                self.isPlaying = false
                self.isFadingOut = false
            }
        }
        return true
    }

    /// Focus Fade: плавно возвращает громкость и продолжает воспроизведение
    /// с того места, где оно было поставлено на паузу.
    func fadeInResume(duration: TimeInterval = 1.5) {
        // Возврат может произойти раньше, чем затухание доиграло: тогда трек ещё
        // играет, но громкость уже падает. Такой возврат тоже нужно обработать,
        // иначе музыка дойдёт до нуля и встанет на паузу.
        let interruptingFade = isFadingOut

        guard currentTrack != nil, !isTransitioning else { return }
        guard !isPlaying || interruptingFade else { return }

        let channel = channels[activeIndex]
        guard channel.file != nil else { return }

        // Снимает незавершённое затухание и сбрасывает isFadingOut.
        cancelRamp()

        let sounding = channels.filter { $0.file != nil }
        for c in sounding {
            c.player.volume = 0
            c.player.play()
        }
        isPlaying = true
        startTimeTimer()

        let total = max(0.05, duration)
        let steps = max(2, Int(total * rampStepsPerSecond))
        let interval = total / Double(steps)

        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)
            for c in sounding {
                c.player.volume = progress
            }

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil
                // Полная громкость: вне переходов каналы всегда звучат на 1.0.
                for c in sounding {
                    c.player.volume = 1.0
                }
            }
        }
    }

    /// Проверяет, что файл открывается и содержит звук.
    static func canOpen(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        return file.length > 0 && format.sampleRate > 0 && format.channelCount > 0
    }

    func stop() {
        cancelRamp()
        for channel in channels {
            channel.generation += 1
            channel.player.stop()
            channel.player.volume = 1.0
            resetLowPass(channel)
            channel.file = nil
        }
        stopTimeTimer()
        isPlaying = false
        isTransitioning = false
        isFadingOut = false
        currentTime = 0
        currentTrack = nil
        activeFileOffset = 0
    }

    func pause() {
        guard isPlaying, !isTransitioning else { return }
        channels[activeIndex].player.pause()
        stopTimeTimer()
        isPlaying = false
    }

    func resume() {
        guard !isPlaying, currentTrack != nil, !isTransitioning else { return }
        let channel = channels[activeIndex]
        guard channel.file != nil else { return }
        channel.player.play()
        isPlaying = true
        startTimeTimer()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if currentTrack != nil {
            resume()
        }
    }

    // MARK: - Seek (перемотка по времени трека, относительно trimStart)

    /// Перематывает трек на указанную позицию (0 = начало trimStart, effectiveDuration = trimEnd).
    /// Работает и во время воспроизведения, и на паузе.
    func seek(to time: TimeInterval) {
        performSeek(to: time, autoplay: isPlaying)
    }

    /// Перемотка трека, который может ещё не играть: при необходимости трек
    /// сначала загружается на паузе, затем ставится нужная позиция.
    /// Так работает клик по waveform для выделенного трека до его запуска.
    func seekOrLoad(track: Track, position: TimeInterval) {
        if currentTrack?.id != track.id {
            guard hardSwitch(to: track, autoplay: false) else { return }
        }
        performSeek(to: position, autoplay: false)
    }

    private func performSeek(to time: TimeInterval, autoplay: Bool) {
        guard let track = currentTrack else { return }

        // Останавливаем активный канал
        let channel = channels[activeIndex]
        channel.player.stop()
        stopTimeTimer()
        isPlaying = false

        // Перезапускаем с новой позиции
        let position = max(0, min(time, track.effectiveDuration))
        if startSegment(track: track, onChannel: activeIndex, position: position, autoplay: autoplay) {
            if autoplay {
                isPlaying = true
                startTimeTimer()
            }
        }
    }

    // MARK: - Синхронизация изменённого трека

    /// Обновляет данные играющего трека (цвет, trim-точки, флаги) без перезапуска.
    /// Если изменились trim-точки — пересчитывает позицию, чтобы воспроизведение
    /// продолжалось с того же места в новом сегменте.
    func syncCurrentTrack(_ track: Track) {
        guard let old = currentTrack, old.id == track.id else { return }
        let wasPlaying = isPlaying
        let position = currentTime

        currentTrack = track

        // Границы сегмента изменились — надо перепланировать воспроизведение.
        if old.trimStart != track.trimStart || old.trimEnd != track.trimEnd {
            let clamped = max(0, min(position, track.effectiveDuration))
            // Сохраняем прежнее состояние: если трек стоял на паузе, он должен
            // остаться на паузе после перепланирования.
            if startSegment(track: track, onChannel: activeIndex, position: clamped, autoplay: wasPlaying) {
                if wasPlaying {
                    isPlaying = true
                    startTimeTimer()
                }
            }
        }
    }

    // MARK: - Громкость

    func applyVolume() {
        engine.mainMixerNode.outputVolume = Float(max(0, min(settings.volume, 1)))
    }

    // MARK: - Переключение треков

    @discardableResult
    private func hardSwitch(to track: Track, position: TimeInterval = 0, autoplay: Bool = true) -> Bool {
        cancelRamp()

        for channel in channels {
            channel.generation += 1
            channel.player.stop()
            channel.player.volume = 1.0
            resetLowPass(channel)
            // Каналы остановлены — файл больше не звучит. Без этого `file != nil`
            // не означал бы «канал звучит», и плавные эффекты трогали бы тишину.
            channel.file = nil
        }

        let index = 0
        activeIndex = index
        let started = startSegment(track: track, onChannel: index, position: position, autoplay: autoplay)
        if started && autoplay {
            isPlaying = true
        }
        return started
    }

    private func transitionWithCrossfade(to track: Track, from position: TimeInterval = 0) {
        let oldIndex = activeIndex
        let newIndex = 1 - activeIndex
        cancelRamp()

        guard startSegment(track: track, onChannel: newIndex, position: position, startVolume: 0) else { return }

        activeIndex = newIndex
        isTransitioning = true
        isPlaying = true

        let duration = max(0.3, settings.crossfadeDuration)
        let steps = max(2, Int(duration * rampStepsPerSecond))
        let interval = duration / Double(steps)
        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        let oldChannel = channels[oldIndex]
        let newChannel = channels[newIndex]

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)

            oldChannel.player.volume = 1 - progress
            newChannel.player.volume = progress

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil
                oldChannel.generation += 1
                oldChannel.player.stop()
                oldChannel.player.volume = 1.0
                oldChannel.file = nil
                self.isTransitioning = false
            }
        }
    }

    private func transitionWithHighCut(to track: Track, from position: TimeInterval = 0) {
        cancelRamp()

        let oldIndex = activeIndex
        let oldChannel = channels[oldIndex]

        isTransitioning = true
        isPlaying = true

        let duration = max(0.2, settings.highCutDuration)
        let steps = max(2, Int(duration * rampStepsPerSecond))
        let interval = duration / Double(steps)
        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        if let band = oldChannel.eq.bands.first {
            band.bypass = false
            band.frequency = lowPassOpenFrequency
        }

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)

            if let band = oldChannel.eq.bands.first {
                let curve = pow(progress, 1.5)
                band.frequency = self.lowPassOpenFrequency * pow(self.lowPassClosedFrequency / self.lowPassOpenFrequency, curve)
            }
            oldChannel.player.volume = max(0, 1 - progress * 0.6)

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil

                oldChannel.generation += 1
                oldChannel.player.stop()
                oldChannel.player.volume = 1.0
                oldChannel.file = nil
                self.resetLowPass(oldChannel)

                // Пауза после high-cut перед запуском следующего
                let pauseAfter = self.settings.highCutPauseAfter
                if pauseAfter > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pauseAfter) { [weak self] in
                        guard let self else { return }
                        let newIndex = 1 - oldIndex
                        self.activeIndex = newIndex
                        if self.startSegment(track: track, onChannel: newIndex, position: position) {
                            self.isPlaying = true
                        }
                        self.isTransitioning = false
                    }
                } else {
                    let newIndex = 1 - oldIndex
                    self.activeIndex = newIndex
                    if self.startSegment(track: track, onChannel: newIndex, position: position) {
                        self.isPlaying = true
                    }
                    self.isTransitioning = false
                }
            }
        }
    }

    /// Запускает сегмент трека с trimStart до trimEnd (или до конца файла).
    /// `position` — время относительно trimStart (0 = начало trimStart).
    @discardableResult
    private func startSegment(track: Track, onChannel index: Int, position: TimeInterval = 0, startVolume: Float = 1.0, autoplay: Bool = true) -> Bool {
        guard index >= 0, index < channels.count else { return false }
        let channel = channels[index]

        do {
            let file = try AVAudioFile(forReading: track.url)
            let format = file.processingFormat
            let rate = format.sampleRate
            let totalFrames = file.length

            // Файл должен быть корректным: без этого движок нельзя подключать.
            guard rate > 0, rate <= 768_000,
                  format.channelCount > 0,
                  totalFrames > 0 else {
                NSLog("DJPlayer: неподдерживаемый формат — \(track.path)")
                return false
            }

            // Позиция в файле = trimStart + position
            let startSec = max(0, track.trimStart + position)
            let startFrame = AVAudioFramePosition(startSec * rate)
            
            let endSec = track.trimEnd ?? (Double(totalFrames) / rate)
            let endFrame = min(totalFrames, AVAudioFramePosition(endSec * rate))
            let rawFrames = max(0, endFrame - startFrame)
            let frameCount = AVAudioFrameCount(min(Double(rawFrames), Double(AVAudioFrameCount.max)))

            guard frameCount > 0 else {
                // Сегмент пустой — трек считается законченным
                DispatchQueue.main.async { [weak self] in
                    self?.onTrackFinished?()
                }
                return false
            }

            channel.generation += 1
            let generation = channel.generation

            channel.player.stop()
            channel.player.volume = startVolume
            resetLowPass(channel)

            // Многоканальные файлы (5.1 и подобные) идём в обход EQ: AVAudioUnitEQ
            // не рассчитан на произвольное число каналов и может уронить движок.
            // Микшер сам приведёт их к стерео.
            // Граф не перестраивается на ходу. connect() на работающем движке с
            // несовпадающим форматом бросает NSException, которую Swift не ловит,
            // — это и есть причина аварийного завершения. Поэтому граф фиксирован
            // (см. init), а формат файла приводится к нему в player-узле.
            guard engine.isRunning || startEngineIfNeeded() else { return false }

            channel.file = file

            // Формат файла может не совпадать с графом. Сегмент читается и
            // приводится к формату графа заранее, поэтому несовпадение форматов
            // не доходит до AVFAudio и не может уронить приложение.
            guard let graphFormat = channel.connectedFormat,
                  let segmentBuffer = Self.readSegment(file: file,
                                                       startFrame: startFrame,
                                                       frameCount: frameCount,
                                                       to: graphFormat) else {
                NSLog("DJPlayer: не удалось подготовить сегмент — \(track.path)")
                return false
            }

            channel.player.scheduleBuffer(segmentBuffer, at: nil, options: [], completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard channel.generation == generation else { return }
                    guard !self.isFadingOut else { return }
                    if self.activeIndex == index && !self.isTransitioning {
                        self.stopTimeTimer()
                        self.isPlaying = false
                        self.currentTime = track.effectiveDuration
                        self.onTrackFinished?()
                    }
                }
            })
            // При autoplay = false трек загружается, но остаётся на паузе:
            // это нужно, чтобы можно было перематывать ещё не игравший трек.
            if autoplay {
                channel.player.play()
            }

            currentTrack = track
            currentTime = position
            activeFileOffset = startSec
            if autoplay {
                startTimeTimer()
            }
            // Пики и длительность считает AppModel: у движка не должно быть
            // второй копии waveform, из-за которой на графике оказывался
            // результат предыдущего трека.
            return true
        } catch {
            NSLog("DJPlayer: не удалось открыть файл \(track.path) — \(error.localizedDescription)")
            return false
        }
    }

    /// Читает сегмент файла и приводит его к формату графа. Возвращает nil,
    /// если конвертация невозможна. Никаких исключений AVFAudio здесь не
    /// вызывается на несовпадающих форматах: конвертер сообщает об ошибке штатно.
    private static func readSegment(file: AVAudioFile,
                                    startFrame: AVAudioFramePosition,
                                    frameCount: AVAudioFrameCount,
                                    to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }

        // Читаем сегмент во входной буфер.
        file.framePosition = startFrame
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frameCount) else { return nil }
        do {
            try file.read(into: input, frameCount: frameCount)
        } catch {
            return nil
        }
        guard input.frameLength > 0 else { return nil }

        // Конвертируем в формат графа.
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Запускает движок, если он остановлен. Перестроения графа здесь нет.
    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            NSLog("DJPlayer: не удалось запустить аудиодвижок — \(error.localizedDescription)")
            return false
        }
    }

    private func resetLowPass(_ channel: Channel) {
        if let band = channel.eq.bands.first {
            band.frequency = lowPassOpenFrequency
            band.bypass = true
        }
    }

    private func cancelRamp() {
        rampGeneration += 1
        rampTimer?.invalidate()
        rampTimer = nil
        isFadingOut = false
    }

    // MARK: - Отсчёт времени

    private func startTimeTimer() {
        stopTimeTimer()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        guard let track = currentTrack else { return }
        let channel = channels[activeIndex]
        guard let nodeTime = channel.player.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = channel.player.playerTime(forNodeTime: nodeTime) else {
            return
        }
        let rate = channel.file?.processingFormat.sampleRate ?? 44100
        guard rate > 0 else { return }
        
        // Текущая позиция в файле
        let fileTime = activeFileOffset + Double(playerTime.sampleTime) / rate
        
        // Текущее время относительно trimStart
        let relativeTime = fileTime - track.trimStart
        currentTime = max(0, min(track.effectiveDuration, relativeTime))
    }

}
