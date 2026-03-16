import SwiftUI
import Combine
import AVFoundation
import Vision
import CoreMotion
import CoreImage // Added to handle the raw camera frame conversion

@main
struct BrowStencilApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class DeviceTiltManager: ObservableObject {
    private let motionManager = CMMotionManager()
    
    // Publishes the left/right tilt in radians
    @Published var roll: Double = 0.0
    
    init() {
        if motionManager.isDeviceMotionAvailable {
            // Update 60 times a second for smooth animation
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
                guard let data = data else { return }
                // In portrait mode, 'roll' gives us the left-to-right tilt
                self?.roll = data.attitude.roll
            }
        }
    }
    
    deinit {
        motionManager.stopDeviceMotionUpdates()
    }
}

// MARK: - Main UI View
struct ContentView: View {
    @StateObject private var permissionModel = CameraPermissionModel()
    @StateObject private var tiltManager = DeviceTiltManager()
    @State private var showLevelIndicator: Bool = true
    @State private var triggerCapture: Bool = false
    @State private var capturedImage: UIImage? = nil
    
    // State for the snackbar
    @State private var showSavedSnackBar: Bool = false
    
    var body: some View {
        ZStack {
            Color(white: 0.98).ignoresSafeArea()
            
            switch permissionModel.status {
            case .authorized:
                mainAppContent
            case .notDetermined:
                permissionView(
                    title: "Camera Access Needed",
                    message: "This app uses the front camera and Vision face landmarks to draw a real-time brow stencil."
                ) {
                    permissionModel.requestAccess()
                }
            case .denied, .restricted:
                permissionView(
                    title: "Camera Access Off",
                    message: "Turn on camera access in Settings so the app can map your brows."
                ) {
                    permissionModel.openSettings()
                }
            @unknown default:
                permissionView(
                    title: "Camera Unavailable",
                    message: "This device state is not supported by the demo."
                ) { }
            }
            
            // Snackbar UI
            if showSavedSnackBar {
                VStack {
                    Text("Saved to Camera Roll")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(20)
                        .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 3)
                        .padding(.top, 50)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .task {
            if permissionModel.status == .notDetermined {
                permissionModel.requestAccess()
            }
        }
        // Intercept the captured image, save it, and show snackbar
        .onChange(of: capturedImage) { newValue in
            if let image = newValue {
                // Save to photos directly
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                
                // Clear state
                capturedImage = nil
                
                // Show snackbar
                withAnimation(.spring()) {
                    showSavedSnackBar = true
                }
                
                // Hide snackbar after 2.5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.spring()) {
                        showSavedSnackBar = false
                    }
                }
            }
        }
    }
    
    // The exact UI layout matching the screenshot
    @ViewBuilder
    private var mainAppContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Top White Area with Navigation and Level
                VStack(spacing: 16) {
                    // Navigation Bar
                    HStack {
                        Image(systemName: "gearshape")
                            .font(.system(size: 24))
                            .foregroundColor(Color(white: 0.4))
                        
                        Spacer()
                        
                        Text("Brow Mapper")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(Color(white: 0.2))
                        
                        Spacer()
                        
                        Image(systemName: "questionmark")
                            .font(.system(size: 24))
                            .foregroundColor(Color(white: 0.4))
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, showLevelIndicator ? 0 : 16)
                    
                    // Level Indicator
                    if showLevelIndicator {
                        ZStack {
                            Capsule()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 200, height: 8)
                            
                            let rawOffset = CGFloat(tiltManager.roll * 150.0)
                            let xOffset = min(max(rawOffset, -96), 96)
                            let isLevel = abs(tiltManager.roll) < 0.05
                            
                            Circle()
                                .fill(isLevel ? Color.green.opacity(0.8) : Color.white)
                                .frame(width: 6, height: 6)
                                .offset(x: xOffset)
                                .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.8), value: xOffset)
                        }
                        .padding(.bottom, 12)
                        // This makes it slide up and fade out cleanly
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, 10) // safe area padding
                .background(Color.white)
                .zIndex(2)
                
                // Live Camera View Layer
                BrowMappingCameraView(triggerCapture: $triggerCapture, capturedImage: $capturedImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                
                // Bottom White Area
                Color(white: 0.98)
                    .frame(height: 190)
            }
            .ignoresSafeArea(.keyboard)
            
            // Floating Overlays (Overlaps camera and bottom sheet)
            VStack(spacing: 16) {
                // Info Card
                /*
                HStack(spacing: 16) {
                    // Avatar Placeholder
                    ZStack {
                        Circle()
                            .fill(Color(white: 0.9))
                            .frame(width: 48, height: 48)
                        Image(systemName: "person.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 24)
                            .foregroundColor(.gray)
                            .offset(y: 4)
                            .clipShape(Circle())
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sarah Jenkins")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(Color(white: 0.2))
                        Text("Last visit: 2 weeks ago • Soft arch")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(Color.gray)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white)
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
                */
                // Controls Card
                HStack {
                    VStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 22))
                            .foregroundColor(Color(white: 0.3))
                        Text("Align Points")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.gray)
                    }
                    .frame(maxWidth: .infinity)
                    
                    Divider().frame(height: 40)
                    
                    // Level Button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showLevelIndicator.toggle()
                        }
                    }) {
                        VStack(spacing: 10) {
                            ZStack {
                                Capsule().fill(showLevelIndicator ? Color(white: 0.4) : Color.gray.opacity(0.3))
                                    .frame(width: 40, height: 16)
                                HStack(spacing: 6) {
                                    Circle().fill(showLevelIndicator ? Color.green : Color.gray).frame(width: 4, height: 4)
                                }
                            }
                            .frame(height: 22)
                            
                            Text("Level")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(showLevelIndicator ? Color(white: 0.3) : Color.gray)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    
                    Divider().frame(height: 40)
                    
                    Button(action: {
                        triggerCapture = true
                    }) {
                        VStack(spacing: 10) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22))
                                .foregroundColor(Color(white: 0.3))
                            Text("Take Photo")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color.gray)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .background(Color.white)
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
                
                // Save Mapping Button
                Button(action: { }) {
                    Text("SAVE MAPPING")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color(white: 0.2))
                        .cornerRadius(30)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }
    
    @ViewBuilder
    private func permissionView(title: String, message: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.black)
            
            Text(message)
                .multilineTextAlignment(.center)
                .font(.system(size: 17))
                .foregroundColor(.gray)
                .frame(maxWidth: 320)
            
            Button(action: action) {
                Text(permissionModel.status == .notDetermined ? "Allow Camera" : "Open Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.blue, in: Capsule())
                    .foregroundColor(.white)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Camera Permission Model
final class CameraPermissionModel: ObservableObject {
    @Published var status = AVCaptureDevice.authorizationStatus(for: .video)
    
    func requestAccess() {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if currentStatus == .authorized {
            DispatchQueue.main.async { self.status = currentStatus }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async {
                self?.status = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
    
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - SwiftUI Camera Representative
struct BrowMappingCameraView: UIViewRepresentable {
    @Binding var triggerCapture: Bool
    @Binding var capturedImage: UIImage?

    func makeUIView(context: Context) -> BrowMappingPreviewView {
        let view = BrowMappingPreviewView()
        view.start()
        return view
    }

    func updateUIView(_ uiView: BrowMappingPreviewView, context: Context) {
        if triggerCapture {
            DispatchQueue.main.async {
                // Immediately reset the trigger to prevent looping
                self.triggerCapture = false
                
                // Request the frame from the camera view asynchronously
                uiView.takeSnapshot { image in
                    DispatchQueue.main.async {
                        self.capturedImage = image
                    }
                }
            }
        }
    }

    static func dismantleUIView(_ uiView: BrowMappingPreviewView, coordinator: ()) {
        uiView.stop()
    }
}

// MARK: - Vision Camera View
final class BrowMappingPreviewView: UIView, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    
    private let redGuidesLayer = CAShapeLayer()
    private let purpleGuidesLayer = CAShapeLayer()
    
    private let sessionQueue = DispatchQueue(label: "brow.session.queue")
    private let videoQueue = DispatchQueue(label: "brow.video.queue")
    
    private let overlaySmoother = BrowOverlaySmoother(alpha: 0.25)
    
    private var isConfigured = false
    private var isRunning = false
    private var isProcessingFrame = false
    private var missedFrames = 0
    private var currentViewSize: CGSize = .zero
    
    // Store the callback so we can execute it when the next camera frame hits
    private var snapshotCompletion: ((UIImage?) -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        redGuidesLayer.frame = bounds
        purpleGuidesLayer.frame = bounds
        currentViewSize = bounds.size
    }
    
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configureSession() }
            guard self.isConfigured, !self.isRunning else { return }
            self.session.startRunning()
            self.isRunning = true
        }
    }
    
    func takeSnapshot(completion: @escaping (UIImage?) -> Void) {
        videoQueue.async { [weak self] in
            self?.snapshotCompletion = completion
        }
    }
    
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.session.stopRunning()
            self.isRunning = false
        }
    }
    
    private func configureLayers() {
        backgroundColor = .black
        
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
        
        // Setup Yellow Dashed Lines (Previously Red)
        redGuidesLayer.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        redGuidesLayer.fillColor = UIColor.clear.cgColor
        redGuidesLayer.lineWidth = 1
        redGuidesLayer.lineDashPattern = [6, 4]
        redGuidesLayer.lineCap = .butt
        redGuidesLayer.lineJoin = .miter
        layer.addSublayer(redGuidesLayer)
        
        // Setup White Dashed Lines (Previously Purple)
        purpleGuidesLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        purpleGuidesLayer.fillColor = UIColor.clear.cgColor
        purpleGuidesLayer.lineWidth = 1
        purpleGuidesLayer.lineCap = .butt
        purpleGuidesLayer.lineJoin = .miter
        layer.addSublayer(purpleGuidesLayer)
    }
    
    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }
        
        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else { return }
        session.addInput(input)
        
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        
        if let previewConnection = previewLayer.connection {
            if previewConnection.isVideoOrientationSupported { previewConnection.videoOrientation = .portrait }
            if previewConnection.isVideoMirroringSupported {
                previewConnection.automaticallyAdjustsVideoMirroring = false
                previewConnection.isVideoMirrored = true
            }
        }
        
        if let videoConnection = output.connection(with: .video), videoConnection.isVideoOrientationSupported {
            videoConnection.videoOrientation = .portrait
        }
        
        isConfigured = true
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isProcessingFrame, currentViewSize.width > 0, currentViewSize.height > 0 else { return }
        
        isProcessingFrame = true
        defer { isProcessingFrame = false }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Check if there's a pending snapshot request
        var pendingCompletion: ((UIImage?) -> Void)? = nil
        if let completion = snapshotCompletion {
            pendingCompletion = completion
            snapshotCompletion = nil // Clear it immediately
        }
        
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        do { try handler.perform([request]) } catch {
            processSnapshot(pendingCompletion, pixelBuffer: pixelBuffer)
            return
        }
        
        guard
            let face = request.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area }),
            let landmarks = face.landmarks
        else {
            handleMissedFace()
            processSnapshot(pendingCompletion, pixelBuffer: pixelBuffer)
            return
        }
        
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        
        guard let geometry = BrowGeometryBuilder.makeGeometry(
            face: face,
            landmarks: landmarks,
            imageSize: imageSize,
            viewSize: currentViewSize
        ) else {
            handleMissedFace()
            processSnapshot(pendingCompletion, pixelBuffer: pixelBuffer)
            return
        }
        
        missedFrames = 0
        let smoothed = overlaySmoother.smoothed(with: geometry)
        
        // Update the visual paths on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.draw(smoothed)
        }
        
        // Fire the snapshot sequence if requested, using the exact buffer and current layer state
        processSnapshot(pendingCompletion, pixelBuffer: pixelBuffer)
    }
    
    private func processSnapshot(_ completion: ((UIImage?) -> Void)?, pixelBuffer: CVPixelBuffer) {
        guard let completion = completion else { return }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let viewSize = self.currentViewSize
        
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            // Front camera is naturally unmirrored at this stage, so we flip it to match the screen
            let baseImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .upMirrored)
            
            // Hop to the main thread to render the final composite safely
            DispatchQueue.main.async {
                let renderer = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: viewSize))
                let finalImage = renderer.image { ctx in
                    // 1. Calculate the aspect fill rect to match the preview layer scale perfectly
                    let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
                    let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                    let xOffset = (viewSize.width - scaledSize.width) * 0.5
                    let yOffset = (viewSize.height - scaledSize.height) * 0.5
                    let drawRect = CGRect(x: xOffset, y: yOffset, width: scaledSize.width, height: scaledSize.height)
                    
                    // 2. Draw the camera frame
                    baseImage.draw(in: drawRect)
                    
                    // 3. Render the guide layers explicitly on top
                    self.redGuidesLayer.render(in: ctx.cgContext)
                    self.purpleGuidesLayer.render(in: ctx.cgContext)
                }
                
                completion(finalImage)
            }
        } else {
            DispatchQueue.main.async { completion(nil) }
        }
    }
    
    private func handleMissedFace() {
        missedFrames += 1
        if missedFrames < 4 { return }
        overlaySmoother.reset()
        DispatchQueue.main.async { [weak self] in
            self?.redGuidesLayer.path = nil
            self?.purpleGuidesLayer.path = nil
        }
    }
    
    private func draw(_ geometry: BrowOverlayGeometry) {
        let redPath = CGMutablePath()
        for line in geometry.redLines {
            guard line.count == 2 else { continue }
            redPath.move(to: line[0])
            redPath.addLine(to: line[1])
        }
        redGuidesLayer.path = redPath
        
        let purplePath = CGMutablePath()
        for line in geometry.purpleLines {
            guard line.count == 2 else { continue }
            purplePath.move(to: line[0])
            purplePath.addLine(to: line[1])
        }
        purpleGuidesLayer.path = purplePath
    }
}

// MARK: - Math and Geometry Construction
private struct BrowGeometryBuilder {
    static func makeGeometry(face: VNFaceObservation, landmarks: VNFaceLandmarks2D, imageSize: CGSize, viewSize: CGSize) -> BrowOverlayGeometry? {
        guard
            let leftBrow = landmarks.leftEyebrow?.imagePoints(in: face, imageSize: imageSize),
            let rightBrow = landmarks.rightEyebrow?.imagePoints(in: face, imageSize: imageSize),
            let leftEye = landmarks.leftEye?.imagePoints(in: face, imageSize: imageSize),
            let rightEye = landmarks.rightEye?.imagePoints(in: face, imageSize: imageSize),
            let nose = landmarks.nose?.imagePoints(in: face, imageSize: imageSize)
        else { return nil }
        
        // Mapped to View space natively
        let mappedLeftBrow = leftBrow.map { $0.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true) }
        let mappedRightBrow = rightBrow.map { $0.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true) }
        let mappedLeftEye = leftEye.map { $0.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true) }
        let mappedRightEye = rightEye.map { $0.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true) }
        let mappedNose = nose.map { $0.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true) }
        
        let mappedLeftPupil = landmarks.leftPupil?.imagePoints(in: face, imageSize: imageSize).first?.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true)
        let mappedRightPupil = landmarks.rightPupil?.imagePoints(in: face, imageSize: imageSize).first?.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true)
        
        // 1. Identify screen-left and screen-right nostrils
        let lowerNose = mappedNose.filter { $0.y >= (mappedNose.map(\.y).reduce(0, +) / CGFloat(mappedNose.count)) }
        guard
            let screenLeftNostril = lowerNose.min(by: { $0.x < $1.x }),
            let screenRightNostril = lowerNose.max(by: { $0.x < $1.x })
        else { return nil }
        
        // Vision's "left" is the user's physical left, which is on the RIGHT side of the mirrored screen.
        let physLeftNostril = screenRightNostril
        let physRightNostril = screenLeftNostril
        
        let centerX = mappedNose.map(\.x).reduce(0, +) / CGFloat(max(mappedNose.count, 1))
        let noseTipY = mappedNose.max(by: { $0.y < $1.y })?.y ?? screenLeftNostril.y
        
        let leftPupilPt = mappedLeftPupil ?? mappedLeftEye.center()
        let rightPupilPt = mappedRightPupil ?? mappedRightEye.center()
        
        // Outer eye corners (Physical Left is Screen Right, so its outer corner is max X)
        let leftOuterEyePt = mappedLeftEye.max(by: { $0.x < $1.x }) ?? .zero
        // Outer eye corners (Physical Right is Screen Left, so its outer corner is min X)
        let rightOuterEyePt = mappedRightEye.min(by: { $0.x < $1.x }) ?? .zero
        
        let leftBrowStart = mappedLeftBrow.max(by: { $0.x < $1.x }) ?? .zero
        let rightBrowStart = mappedRightBrow.min(by: { $0.x < $1.x }) ?? .zero
        
        let topY = (leftBrowStart.y + rightBrowStart.y) * 0.5 - 10
        let bottomY = (leftBrowStart.y + rightBrowStart.y) * 0.5 + 10
        
        let extL = screenLeftNostril.x - 70
        let extR = screenRightNostril.x + 70
        
        // Yellow Lines (Verticals and Horizontals)
        let redLines = [
            [CGPoint(x: centerX, y: 0), CGPoint(x: centerX, y: noseTipY)], // Center Vertical
            [CGPoint(x: screenLeftNostril.x, y: 0), screenLeftNostril], // Left Inner Vertical
            [CGPoint(x: screenRightNostril.x, y: 0), screenRightNostril], // Right Inner Vertical
            [CGPoint(x: extL, y: topY), CGPoint(x: extR, y: topY)], // Top Horizontal
            [CGPoint(x: extL, y: bottomY), CGPoint(x: extR, y: bottomY)] // Bottom Horizontal
        ]
        
        let length: CGFloat = 450
        
        // Map physical sides to physical sides to prevent crossing
        let lArchDir = (leftPupilPt - physLeftNostril).normalized
        let lTailDir = (leftOuterEyePt - physLeftNostril).normalized
        let rArchDir = (rightPupilPt - physRightNostril).normalized
        let rTailDir = (rightOuterEyePt - physRightNostril).normalized
        
        // White Lines (Diagonals)
        let purpleLines = [
            [physLeftNostril, physLeftNostril + lArchDir * length], // Left Arch
            [physLeftNostril, physLeftNostril + lTailDir * length], // Left Tail
            [physRightNostril, physRightNostril + rArchDir * length], // Right Arch
            [physRightNostril, physRightNostril + rTailDir * length]  // Right Tail
        ]
        
        return BrowOverlayGeometry(redLines: redLines, purpleLines: purpleLines)
    }
}

// MARK: - Geometry State
private struct BrowOverlayGeometry {
    let redLines: [[CGPoint]]
    let purpleLines: [[CGPoint]]
    
    func blended(with previous: BrowOverlayGeometry, alpha: CGFloat) -> BrowOverlayGeometry {
        return BrowOverlayGeometry(
            redLines: blendLines(current: redLines, previous: previous.redLines, alpha: alpha),
            purpleLines: blendLines(current: purpleLines, previous: previous.purpleLines, alpha: alpha)
        )
    }
    
    private func blendLines(current: [[CGPoint]], previous: [[CGPoint]], alpha: CGFloat) -> [[CGPoint]] {
        guard current.count == previous.count else { return current }
        return zip(current, previous).map { currLine, prevLine in
            guard currLine.count == prevLine.count else { return currLine }
            return zip(currLine, prevLine).map { cPt, pPt in
                CGPoint(x: pPt.x + (cPt.x - pPt.x) * alpha, y: pPt.y + (cPt.y - pPt.y) * alpha)
            }
        }
    }
}

// MARK: - Point Smoothing
private final class BrowOverlaySmoother {
    private let alpha: CGFloat
    private var previous: BrowOverlayGeometry?
    
    init(alpha: CGFloat) { self.alpha = alpha }
    
    func smoothed(with current: BrowOverlayGeometry) -> BrowOverlayGeometry {
        guard let prev = previous else {
            previous = current
            return current
        }
        let blended = current.blended(with: prev, alpha: alpha)
        previous = blended
        return blended
    }
    
    func reset() { previous = nil }
}

// MARK: - Helpers & Extensions
private extension VNFaceLandmarkRegion2D {
    func imagePoints(in face: VNFaceObservation, imageSize: CGSize) -> [CGPoint] {
        normalizedPoints.map { point in
            let normalizedX = face.boundingBox.origin.x + CGFloat(point.x) * face.boundingBox.width
            let normalizedY = face.boundingBox.origin.y + CGFloat(point.y) * face.boundingBox.height
            return CGPoint(x: normalizedX * imageSize.width, y: (1 - normalizedY) * imageSize.height)
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

private extension Array where Element == CGPoint {
    func center() -> CGPoint {
        guard !isEmpty else { return .zero }
        let total = reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: total.x / CGFloat(count), y: total.y / CGFloat(count))
    }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }
    var length: CGFloat { sqrt(x * x + y * y) }
    var normalized: CGPoint {
        let len = max(length, 0.0001)
        return CGPoint(x: x / len, y: y / len)
    }
    
    func aspectFillMapped(from imageSize: CGSize, into viewSize: CGSize, mirroredHorizontally: Bool = false) -> CGPoint {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let xOffset = (viewSize.width - scaledSize.width) * 0.5
        let yOffset = (viewSize.height - scaledSize.height) * 0.5
        var point = CGPoint(x: x * scale + xOffset, y: y * scale + yOffset)
        if mirroredHorizontally { point.x = viewSize.width - point.x }
        return point
    }
}
