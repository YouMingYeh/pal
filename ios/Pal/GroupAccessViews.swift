import SwiftUI
import PhotosUI
import AVFoundation
import CoreImage.CIFilterBuiltins

@MainActor
enum PalGroupAccess {
    static func validName(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.utf16.count <= 80
    }
    static func inviteURL(code: String) -> URL {
        var parts = URLComponents(string: "https://pal-jade.vercel.app/join")!
        parts.queryItems = [URLQueryItem(name: "code", value: code)]
        return parts.url!
    }
    static func qrImage(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let extent = code.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: CIColor.white).cropped(to: extent)
        let image = code.composited(over: background).cropped(to: extent)
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let rendered = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}

struct GroupCreateView: View {
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    @State private var photoData: Data?
    @State private var photoPreview: UIImage?
    @State private var preparingPhoto = false
    @State private var photoTask: Task<Void, Never>?
    @State private var clientID = UUID()
    @State private var started = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Menu {
                            Button("Camera", systemImage: "camera") { photo = nil; showingCamera = true }
                            Button("Photo Library", systemImage: "photo.on.rectangle") { photo = nil; showingPhotoLibrary = true }
                            if photoData != nil || preparingPhoto {
                                Button("Remove Photo", systemImage: "trash", role: .destructive, action: removePhoto)
                            }
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                if let photoPreview {
                                    Image(uiImage: photoPreview).resizable().scaledToFill().frame(width: 148, height: 148).clipShape(Circle())
                                } else { AvatarView(name: name, size: 148) }
                                Image(systemName: "camera.fill").font(.system(size: 15, weight: .semibold)).frame(width: 32, height: 32)
                                    .background(.regularMaterial, in: Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1))
                                    .accessibilityHidden(true)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Edit group photo").disabled(started || busy)
                        Spacer()
                    }.padding(.vertical, 24)
                    if preparingPhoto { ProgressView("Preparing photo…").frame(maxWidth: .infinity) }
                }.listRowBackground(Color.clear)
                Section {
                    HStack {
                        Text("Name").foregroundStyle(.secondary)
                        TextField("Group name", text: $name).multilineTextAlignment(.trailing).disabled(started)
                    }
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 80 {
                        Text("Use 80 characters or fewer.").font(.footnote).foregroundStyle(.red)
                    }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                if busy { ProgressView("Creating group…").frame(maxWidth: .infinity) }
            }.disabled(busy)
                .navigationTitle("New group").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(started ? "Retry" : "Create", action: create)
                            .disabled(busy || preparingPhoto || !PalGroupAccess.validName(name))
                    }
                }
                .onChange(of: photo) { _, item in prepare(item) }
                .onDisappear { photoTask?.cancel() }
        }.interactiveDismissDisabled(busy)
            .photosPicker(isPresented: $showingPhotoLibrary, selection: $photo, matching: .images)
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCapture(onCapture: prepareCameraPhoto, onError: { error = $0.localizedDescription })
            }
    }
    private func prepare(_ item: PhotosPickerItem?) {
        photoTask?.cancel()
        guard let item, !started else { preparingPhoto = false; return }
        preparingPhoto = true
        error = nil
        photoTask = Task {
            defer { if !Task.isCancelled { preparingPhoto = false } }
            do {
                guard let original = try await item.loadTransferable(type: Data.self) else { throw PalFailure(message: "Unable to open that photo. Choose another one.") }
                let prepared = try await Task.detached(priority: .userInitiated) { try PalAvatarImage.jpegData(from: original) }.value
                guard !Task.isCancelled else { return }
                photoData = prepared
                photoPreview = UIImage(data: prepared)
            } catch { if !Task.isCancelled && !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
    private func prepareCameraPhoto(_ data: Data) {
        guard !started, !busy else { return }
        photoTask?.cancel()
        preparingPhoto = true
        error = nil
        photoTask = Task {
            defer { if !Task.isCancelled { preparingPhoto = false } }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { try PalAvatarImage.jpegData(from: data) }.value
                try Task.checkCancellation()
                photoData = prepared
                photoPreview = UIImage(data: prepared)
            } catch { if !Task.isCancelled && !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
    private func removePhoto() {
        guard !started, !busy else { return }
        photoTask?.cancel()
        photo = nil
        photoData = nil
        photoPreview = nil
        preparingPhoto = false
    }
    private func create() {
        guard !busy, !preparingPhoto, PalGroupAccess.validName(name) else { return }
        started = true
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await store.createGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), avatarData: photoData, clientID: clientID)
                busy = false
                dismiss()
            } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}

struct GroupJoinView: View {
    private enum CameraState { case loading, ready, denied, unavailable }
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: CameraState = .loading
    @State private var invite = ""
    @State private var scanPaused = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack {
                        if camera == .ready && !scanPaused && scenePhase == .active {
                            PalInviteScanner(onScan: scanned, onUnavailable: {
                                let status = AVCaptureDevice.authorizationStatus(for: .video)
                                camera = status == .denied || status == .restricted ? .denied : .unavailable
                            })
                            RoundedRectangle(cornerRadius: 18).stroke(.white, lineWidth: 2).frame(width: 200, height: 200).allowsHitTesting(false)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: camera == .denied ? "camera.fill" : "qrcode.viewfinder").font(.system(size: 42)).foregroundStyle(.secondary)
                                if busy { ProgressView("Joining group…") }
                                else if camera == .loading { ProgressView("Opening camera…") }
                                else if camera == .denied {
                                    Text("Allow camera access to scan an invite.").multilineTextAlignment(.center)
                                    if let url = URL(string: UIApplication.openSettingsURLString) { Link("Open Settings", destination: url) }
                                } else if camera == .unavailable {
                                    Text("Paste an invite below to join.").multilineTextAlignment(.center)
                                } else { Button("Scan again") { error = nil; scanPaused = false } }
                            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(uiColor: .secondarySystemBackground))
                        }
                    }.frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 24)).listRowInsets(EdgeInsets())
                        .accessibilityLabel("Scan a Pal group invite QR code")
                    Text("Scan a friend’s Pal invite to join their group.").font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
                Section("Have an invite link?") {
                    TextField("Invite link or code", text: $invite).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().keyboardType(.URL)
                    HStack {
                        PasteButton(payloadType: String.self) { values in if let value = values.first { invite = value } }
                        Spacer()
                        Button("Join group") { join(invite) }.disabled(PalStore.inviteCode(from: invite) == nil)
                    }
                }.disabled(busy)
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }.navigationTitle("Join group").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
                .task { await checkCamera() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await checkCamera() } } }
        }.interactiveDismissDisabled(busy)
    }
    private func checkCamera() async {
        guard AVCaptureDevice.default(for: .video) != nil else { camera = .unavailable; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = AVCaptureDevice.default(for: .video) == nil ? .unavailable : .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            camera = granted ? (AVCaptureDevice.default(for: .video) == nil ? .unavailable : .ready) : .denied
        case .denied, .restricted: camera = .denied
        @unknown default: camera = .unavailable
        }
    }
    private func scanned(_ value: String) -> Bool {
        guard !busy else { return true }
        guard PalStore.inviteCode(from: value) != nil else {
            error = "This QR code isn’t a Pal invite."
            return false
        }
        invite = value
        join(value)
        return true
    }
    private func join(_ value: String) {
        guard !busy, PalStore.inviteCode(from: value) != nil else { return }
        scanPaused = true
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await store.joinGroup(code: value); busy = false; dismiss() }
            catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}

struct GroupInviteQRView: View {
    let group: ChatGroup
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let url = PalGroupAccess.inviteURL(code: group.inviteCode)
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Text(group.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                if let image = PalGroupAccess.qrImage(for: url) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 230, maxHeight: 230).padding(20).background(.white, in: RoundedRectangle(cornerRadius: 24)).accessibilityHidden(true)
                } else { Text("The QR code is unavailable. Share the invite link below.").foregroundStyle(.secondary) }
                Text("Ask a friend to scan this code in Pal.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                ShareLink("Share invite link", item: url).buttonStyle(.borderedProminent)
                Text(group.inviteCode).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }.padding(24).navigationTitle("Invite to group").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct PalInviteScanner: UIViewRepresentable {
    let onScan: (String) -> Bool
    let onUnavailable: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onUnavailable: onUnavailable) }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = context.coordinator.session
        context.coordinator.start()
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {}
    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) { coordinator.stop() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "Pal.InviteScanner")
        private let onScan: (String) -> Bool
        private let onUnavailable: () -> Void
        private var consumed = false
        private var lastValue: String?
        init(onScan: @escaping (String) -> Bool, onUnavailable: @escaping () -> Void) {
            self.onScan = onScan; self.onUnavailable = onUnavailable
        }
        func start() {
            queue.async { [self] in
                do {
                    guard let device = AVCaptureDevice.default(for: .video) else { throw PalFailure(message: "Camera unavailable.") }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureMetadataOutput()
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw PalFailure(message: "Camera unavailable.")
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    guard output.availableMetadataObjectTypes.contains(.qr) else {
                        session.commitConfiguration()
                        throw PalFailure(message: "QR scanning unavailable.")
                    }
                    output.metadataObjectTypes = [.qr]
                    session.commitConfiguration()
                    session.startRunning()
                } catch { DispatchQueue.main.async { [self] in onUnavailable() } }
            }
        }
        func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !consumed, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, value != lastValue else { return }
            lastValue = value
            consumed = onScan(value)
        }
    }
}
