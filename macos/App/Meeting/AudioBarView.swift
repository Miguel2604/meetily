import AppKit
import AVFoundation

/// Play/pause, position slider and times for the meeting recording; `seek(to:)` jumps from the transcript.
final class AudioBarView: NSView {
    private let player: AVPlayer
    private let play = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")!, target: nil, action: nil)
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private var observer: Any?
    private var duration: Double = 0

    init(url: URL) {
        player = AVPlayer(url: url)
        super.init(frame: .zero)
        play.isBordered = false
        play.target = self
        play.action = #selector(toggle)
        slider.target = self
        slider.action = #selector(scrub)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel("Playback position")
        for label in [time, total] { label.font = Typography.timestamp; label.textColor = .meetyMutedForeground }
        let row = NSStackView(views: [play, time, slider, total])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        Task { [weak self] in
            guard let seconds = try? await self?.player.currentItem?.asset.load(.duration).seconds, seconds.isFinite else { return }
            self?.duration = seconds
            self?.total.stringValue = Clock.duration(seconds)
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] now in
            MainActor.assumeIsolated { self?.show(now.seconds) }
        }
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        updatePlayIcon()
    }

    private func show(_ seconds: Double) {
        time.stringValue = Clock.duration(seconds)
        if duration > 0, !(slider.cell?.isHighlighted ?? false) { slider.doubleValue = seconds / duration }
        updatePlayIcon()
    }

    private func updatePlayIcon() {
        let playing = player.rate != 0
        play.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playing ? "Pause" : "Play")
    }

    @objc private func toggle() {
        player.rate == 0 ? player.play() : player.pause()
        updatePlayIcon()
    }

    @objc private func scrub() {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: slider.doubleValue * duration, preferredTimescale: 600))
    }
}
