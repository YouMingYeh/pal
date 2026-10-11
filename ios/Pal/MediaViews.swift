import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

private extension Notification.Name {
    static let palPauseAudio = Notification.Name("PalPauseAudio")
}

struct CameraCapture: View {
    var onCapture: (Data) -> Void
    var onError: (Error) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Group {
                if ready {
                    CameraController(onCapture: { data in onCapture(data); dismiss() }, onCancel: { dismiss() }, onError: report)
                        .ignoresSafeArea()
                } else if let issue {
                    VStack(spacing: 16) {
                        ContentUnavailableView("Camera unavailable", systemImage: "camera", description: Text(issue))
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied,
                           let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open Settings", destination: url)
                        }
                    }
                } else { ProgressView("Opening camera…") }
            }
            .navigationTitle("Photo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    report(PalFailure(message: "Take photos on an iPhone with a camera.")); return
                }
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled else { return }
                if allowed { ready = true }
                else { report(PalFailure(message: "Allow camera access in Settings, then try again.")) }
            }
        }
    }
    private func report(_ error: Error) { ready = false; issue = error.localizedDescription; onError(error) }
}

private struct CameraController: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = [UTType.image.identifier]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraController
        init(_ parent: CameraController) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, image.size.width > 0, image.size.height > 0 else {
                parent.onError(PalFailure(message: "Unable to read the camera photo. Please try again.")); return
            }
            let scale = min(1, 1600 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.9) { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            parent.onCapture(data)
        }
    }
}

struct DraftMediaPreview: View {
    let draft: DraftAttachment
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let file = try? AttachmentFiles.url(for: draft), FileManager.default.fileExists(atPath: file.path) {
                if draft.kind == "image", let image = UIImage(contentsOfFile: file.path) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Selected photo")
                } else if draft.kind == "audio" {
                    AudioPlaybackView(url: file, durationMS: draft.durationMS)
                } else { Text("Attachment unavailable").font(.caption) }
            } else { Text("Attachment unavailable. Select it again.").font(.caption) }
            if let onRemove {
                Button("Remove attachment", systemImage: "xmark.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    .accessibilityLabel(draft.kind == "audio" ? "Remove voice message" : "Remove photo")
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MessageAttachmentView: View {
    let attachment: ChatAttachment
    var foreground: Color = PalTheme.ink
    var onRetry: (() -> Void)? = nil
    var body: some View {
        Group {
            if let url = attachment.url {
                if attachment.kind == "image" {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityLabel("Shared photo")
                        case .failure: unavailable
                        case .empty: ProgressView("Loading photo…").frame(width: 160, height: 120)
                        @unknown default: unavailable
                        }
                    }
                } else if attachment.kind == "audio" {
                    AudioPlaybackView(url: url, durationMS: attachment.durationMS, foreground: foreground, onRetry: onRetry).id(url)
                } else { unavailable }
            } else { unavailable }
        }.foregroundStyle(foreground)
    }
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Attachment unavailable", systemImage: "exclamationmark.circle").font(.caption)
            if let onRetry { Button("Try again", action: onRetry).font(.caption) }
        }
    }
}

@MainActor private final class AudioPlayback: ObservableObject {
    let player: AVPlayer
    @Published var requestedPlaying = false
    @Published var elapsed = 0.0
    @Published var issue: String?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failure = item.status == .failed ? (item.error?.localizedDescription ?? "Unable to play this voice message.") : nil
            Task { @MainActor in if let failure { self?.issue = failure; self?.requestedPlaying = false } }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in if time.seconds.isFinite { self?.elapsed = max(0, time.seconds) } }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause(); self?.player.seek(to: .zero) }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .palPauseAudio, object: nil, queue: .main) { [weak self] notification in
            let source = notification.object as? AVPlayer
            Task { @MainActor in if source !== self?.player { self?.pause() } }
        })
    }
    func toggle() {
        if requestedPlaying { pause(); return }
        guard player.currentItem?.status != .failed else {
            issue = player.currentItem?.error?.localizedDescription ?? "Unable to play this voice message."
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            NotificationCenter.default.post(name: .palPauseAudio, object: player)
            issue = nil
            requestedPlaying = true
            player.play()
        } catch { issue = error.localizedDescription }
    }
    func pause() { player.pause(); requestedPlaying = false }
    deinit {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor struct AudioPlaybackView: View {
    @StateObject private var playback: AudioPlayback
    let durationMS: Int?
    var foreground: Color
    var onRetry: (() -> Void)?
    init(url: URL, durationMS: Int? = nil, foreground: Color = PalTheme.ink, onRetry: (() -> Void)? = nil) {
        _playback = StateObject(wrappedValue: AudioPlayback(url: url))
        self.durationMS = durationMS
        self.foreground = foreground
        self.onRetry = onRetry
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button(playback.requestedPlaying ? "Pause voice message" : "Play voice message", systemImage: playback.requestedPlaying ? "pause.fill" : "play.fill") {
                    playback.toggle()
                }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice message").font(.subheadline)
                    Text(durationMS.map { "\(Self.time(playback.elapsed)) / \(Self.time(Double($0) / 1000))" } ?? Self.time(playback.elapsed))
                        .font(.caption.monospacedDigit())
                    if let durationMS, durationMS > 0 {
                        ProgressView(value: min(playback.elapsed, Double(durationMS) / 1000), total: Double(durationMS) / 1000)
                            .tint(foreground).accessibilityLabel("Playback progress")
                    }
                }
            }
            if let issue = playback.issue {
                Text(issue).font(.caption)
                if let onRetry { Button("Try again", action: onRetry).font(.caption) }
            }
        }.foregroundStyle(foreground).onDisappear { playback.pause() }
    }
    private static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

@MainActor final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let maximumDuration = 59.0
    static let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
    @Published private(set) var recording = false
    @Published private(set) var requesting = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var readyURL: URL?
    @Published var issue: String?
    @Published private(set) var permissionDenied = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var temporaryURL: URL?
    private var closed = false
    private var ownsSession = false
    private var interruption: NSObjectProtocol?
    override init() {
        super.init()
        let name: Notification.Name
        if #available(iOS 27.0, *) { name = AVAudioSession.didBecomeInactiveNotification }
        else { name = AVAudioSession.interruptionNotification }
        interruption = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.recording == true { self?.stop(); self?.issue = "Recording stopped because audio was interrupted." }
            }
        }
    }
    func start() async {
        guard !recording, !requesting, !closed else { return }
        requesting = true
        defer { requesting = false }
        do {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard !closed, !Task.isCancelled else { return }
            permissionDenied = !allowed
            guard allowed else { throw PalFailure(message: "Allow microphone access in Settings, then try again.") }
            discardRecording()
            let session = AVAudioSession.sharedInstance()
            NotificationCenter.default.post(name: .palPauseAudio, object: nil)
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            ownsSession = true
            guard session.isInputAvailable else { throw PalFailure(message: "No microphone is available. Record on an iPhone with a microphone.") }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            temporaryURL = file
            let recorder = try AVAudioRecorder(url: file, settings: Self.settings)
            self.recorder = recorder
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record(forDuration: Self.maximumDuration) else {
                throw PalFailure(message: "Unable to start recording. Please try again.")
            }
            issue = nil; elapsed = 0; recording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in if let recorder = self?.recorder, self?.recording == true { self?.elapsed = recorder.currentTime } }
            }
        } catch { issue = error.localizedDescription; discardRecording(); deactivateSession() }
    }
    func stop() {
        guard recording else { return }
        elapsed = max(elapsed, recorder?.currentTime ?? 0)
        recording = false
        timer?.invalidate(); timer = nil
        recorder?.stop()
        readyURL = temporaryURL
        deactivateSession()
    }
    func cancel() { closed = true; discardRecording(); deactivateSession() }
    private func discardRecording() {
        recording = false
        timer?.invalidate(); timer = nil
        let recorder = recorder; self.recorder = nil
        recorder?.stop()
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        temporaryURL = nil; readyURL = nil; elapsed = 0
    }
    private func deactivateSession() {
        guard ownsSession else { return }
        ownsSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder, !self.closed else { return }
            self.recording = false; self.timer?.invalidate(); self.timer = nil
            if flag { self.readyURL = self.temporaryURL }
            else { self.issue = "The voice message could not be saved. Please record it again."; self.readyURL = nil }
            self.deactivateSession()
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder, !self.closed else { return }
            self.issue = error?.localizedDescription ?? "The voice message could not be encoded."
            self.discardRecording(); self.deactivateSession()
        }
    }
    deinit {
        timer?.invalidate()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }
}

struct AudioRecorderView: View {
    var onCapture: (DraftAttachment) -> Void
    var onError: (Error) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = VoiceRecorder()
    @State private var preparing = false
    @State private var closed = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("\(Int(recorder.elapsed))s").font(.system(.largeTitle, design: .rounded).monospacedDigit())
                    .accessibilityLabel("Recorded \(Int(recorder.elapsed)) seconds")
                Text("Voice messages can be recorded for up to 59 seconds.").font(.footnote).foregroundStyle(.secondary)
                if recorder.recording {
                    Button("Stop recording", systemImage: "stop.circle.fill") { recorder.stop() }.buttonStyle(.borderedProminent)
                } else if let file = recorder.readyURL {
                    AudioPlaybackView(url: file, durationMS: Int(recorder.elapsed * 1000)).id(file)
                    Button("Use recording", systemImage: "checkmark") { useRecording(file) }.buttonStyle(.borderedProminent)
                    Button("Record again", systemImage: "mic") { Task { await recorder.start() } }
                } else {
                    Button("Record", systemImage: "mic.circle.fill") { Task { await recorder.start() } }.buttonStyle(.borderedProminent)
                }
                if recorder.requesting || preparing { ProgressView(recorder.requesting ? "Checking microphone permission…" : "Preparing recording…") }
                if let issue = recorder.issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                if recorder.permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) { Link("Open Settings", destination: url) }
            }.padding(24).disabled(preparing || recorder.requesting)
            .navigationTitle("Voice message").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(preparing) } }
            .interactiveDismissDisabled(preparing)
            .onChange(of: scenePhase) { _, phase in if phase != .active { recorder.stop() } }
            .onDisappear { closed = true; recorder.cancel() }
        }
    }
    private func useRecording(_ file: URL) {
        guard !preparing else { return }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                let draft = try await AttachmentFiles.prepareAudio(fileURL: file)
                if closed { try? AttachmentFiles.remove(draft); return }
                onCapture(draft)
                dismiss()
            } catch {
                if !closed { recorder.issue = error.localizedDescription; onError(error) }
            }
        }
    }
}
