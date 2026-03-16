import SwiftUI
import Combine
import AVFoundation
import Vision

@main
struct BrowStencilApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var permissionModel = CameraPermissionModel()

    var body: some View {
        ZStack {
            switch permissionModel.status {
            case .authorized:
                BrowMappingCameraView()
                    .ignoresSafeArea()

                VStack {
                    HStack {
                        Spacer()

                        Text("Keep your face centered and look straight ahead")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.45), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 16)

                    Spacer()

                    Text("Gold lines = start, arch, tail, and brow-height guides")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(.white)
                        .padding(.bottom, 24)
                }
                .allowsHitTesting(false)

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
        }
        .background(.black)
        .task {
            if permissionModel.status == .notDetermined {
                permissionModel.requestAccess()
            }
        }
    }

    @ViewBuilder
    private func permissionView(title: String, message: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .multilineTextAlignment(.center)
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: 320)

            Button(action: action) {
                Text(permissionModel.status == .notDetermined ? "Allow Camera" : "Open Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

final class CameraPermissionModel: ObservableObject {
    @Published var status = AVCaptureDevice.authorizationStatus(for: .video)

    func requestAccess() {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if currentStatus == .authorized {
            DispatchQueue.main.async {
                self.status = currentStatus
            }
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

struct BrowMappingCameraView: UIViewRepresentable {
    func makeUIView(context: Context) -> BrowMappingPreviewView {
        let view = BrowMappingPreviewView()
        view.start()
        return view
    }

    func updateUIView(_ uiView: BrowMappingPreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: BrowMappingPreviewView, coordinator: ()) {
        uiView.stop()
    }
}

final class BrowMappingPreviewView: UIView, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let stencilFillLayer = CAShapeLayer()
    private let stencilStrokeLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let horizontalGuideLayer = CAShapeLayer()

    private let sessionQueue = DispatchQueue(label: "brow.session.queue")
    private let videoQueue = DispatchQueue(label: "brow.video.queue")

    private let overlaySmoother = BrowOverlaySmoother(alpha: 0.18)

    private var isConfigured = false
    private var isRunning = false
    private var isProcessingFrame = false
    private var missedFrames = 0
    private var currentViewSize: CGSize = .zero

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
        stencilFillLayer.frame = bounds
        stencilStrokeLayer.frame = bounds
        guideLayer.frame = bounds
        horizontalGuideLayer.frame = bounds
        currentViewSize = bounds.size
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured, !self.isRunning else { return }
            self.session.startRunning()
            self.isRunning = true
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

        guideLayer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.95).cgColor
        guideLayer.fillColor = UIColor.clear.cgColor
        guideLayer.lineWidth = 2
        guideLayer.lineCap = .round
        guideLayer.lineJoin = .round
        guideLayer.shadowOpacity = 0.3
        guideLayer.shadowRadius = 2
        guideLayer.shadowOffset = .zero
        layer.addSublayer(guideLayer)

        horizontalGuideLayer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.28).cgColor
        horizontalGuideLayer.fillColor = UIColor.clear.cgColor
        horizontalGuideLayer.lineWidth = 2
        horizontalGuideLayer.lineCap = .round
        horizontalGuideLayer.lineJoin = .round
        layer.addSublayer(horizontalGuideLayer)

        stencilFillLayer.fillColor = UIColor.systemGreen.withAlphaComponent(0.18).cgColor
        stencilFillLayer.strokeColor = UIColor.clear.cgColor
        stencilFillLayer.lineJoin = .round
        stencilFillLayer.isHidden = true
        layer.addSublayer(stencilFillLayer)

        stencilStrokeLayer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.95).cgColor
        stencilStrokeLayer.fillColor = UIColor.clear.cgColor
        stencilStrokeLayer.lineWidth = 2.5
        stencilStrokeLayer.lineJoin = .round
        stencilStrokeLayer.lineCap = .round
        stencilStrokeLayer.shadowOpacity = 0.3
        stencilStrokeLayer.shadowRadius = 2
        stencilStrokeLayer.shadowOffset = .zero
        stencilStrokeLayer.isHidden = true
        layer.addSublayer(stencilStrokeLayer)
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
        }

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else {
            return
        }

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        if let previewConnection = previewLayer.connection {
            if previewConnection.isVideoOrientationSupported {
                previewConnection.videoOrientation = .portrait
            }
            if previewConnection.isVideoMirroringSupported {
                previewConnection.automaticallyAdjustsVideoMirroring = false
                previewConnection.isVideoMirrored = true
            }
        }

        if let videoConnection = output.connection(with: .video) {
            if videoConnection.isVideoOrientationSupported {
                videoConnection.videoOrientation = .portrait
            }
        }

        isConfigured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isProcessingFrame else { return }
        guard currentViewSize.width > 0, currentViewSize.height > 0 else { return }

        isProcessingFrame = true
        defer { isProcessingFrame = false }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceLandmarksRequest()

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard
            let face = request.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area }),
            let landmarks = face.landmarks
        else {
            handleMissedFace()
            return
        }

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        guard
            let geometry = BrowGeometryBuilder.makeGeometry(
                face: face,
                landmarks: landmarks,
                imageSize: imageSize,
                viewSize: currentViewSize
            )
        else {
            handleMissedFace()
            return
        }

        missedFrames = 0
        let smoothed = overlaySmoother.smoothed(with: geometry)
        DispatchQueue.main.async { [weak self] in
            self?.draw(smoothed)
        }
    }

    private func handleMissedFace() {
        missedFrames += 1
        if missedFrames < 4 { return }

        overlaySmoother.reset()
        DispatchQueue.main.async { [weak self] in
            self?.guideLayer.path = nil
            self?.horizontalGuideLayer.path = nil
            self?.stencilFillLayer.path = nil
            self?.stencilStrokeLayer.path = nil
        }
    }

    private func draw(_ geometry: BrowOverlayGeometry) {
        let guidePath = UIBezierPath()
        geometry.guideLines.forEach { line in
            guard line.count == 2 else { return }
            guidePath.move(to: line[0])
            guidePath.addLine(to: line[1])
        }

        let horizontalPath = UIBezierPath()
        if geometry.horizontalGuideLine.count == 2 {
            horizontalPath.move(to: geometry.horizontalGuideLine[0])
            horizontalPath.addLine(to: geometry.horizontalGuideLine[1])
        }

        guideLayer.path = guidePath.cgPath
        horizontalGuideLayer.path = horizontalPath.cgPath
        stencilFillLayer.path = nil
        stencilStrokeLayer.path = nil
    }
}

private struct BrowGeometryBuilder {
    static func makeGeometry(
        face: VNFaceObservation,
        landmarks: VNFaceLandmarks2D,
        imageSize: CGSize,
        viewSize: CGSize
    ) -> BrowOverlayGeometry? {
        guard
            let leftBrowRegion = landmarks.leftEyebrow,
            let rightBrowRegion = landmarks.rightEyebrow,
            let leftEyeRegion = landmarks.leftEye,
            let rightEyeRegion = landmarks.rightEye,
            let noseRegion = landmarks.nose
        else {
            return nil
        }

        let leftBrow = leftBrowRegion.imagePoints(in: face, imageSize: imageSize).sortedByX()
        let rightBrow = rightBrowRegion.imagePoints(in: face, imageSize: imageSize).sortedByX()
        let leftEye = leftEyeRegion.imagePoints(in: face, imageSize: imageSize)
        let rightEye = rightEyeRegion.imagePoints(in: face, imageSize: imageSize)
        let nose = noseRegion.imagePoints(in: face, imageSize: imageSize)

        guard leftBrow.count >= 3, rightBrow.count >= 3, leftEye.count >= 4, rightEye.count >= 4, nose.count >= 3 else {
            return nil
        }

        let faceRect = face.boundingBox.imageRect(in: imageSize)
        let faceCenterX = faceRect.midX
        let lowerNose = nose.filteredLowerHalf()
        guard
            let innerLeftNostril = lowerNose.min(by: { $0.x < $1.x }),
            let innerRightNostril = lowerNose.max(by: { $0.x < $1.x })
        else {
            return nil
        }

        let leftEyeInfo = EyeInfo(points: leftEye, pupil: landmarks.leftPupil?.imagePoints(in: face, imageSize: imageSize).first, faceCenterX: faceCenterX)
        let rightEyeInfo = EyeInfo(points: rightEye, pupil: landmarks.rightPupil?.imagePoints(in: face, imageSize: imageSize).first, faceCenterX: faceCenterX)

        guard
            let leftShape = mappedShape(
                brow: leftBrow,
                eye: leftEyeInfo,
                nostrilPair: (innerLeftNostril, innerRightNostril),
                faceCenterX: faceCenterX,
                faceRect: faceRect,
                imageSize: imageSize,
                viewSize: viewSize
            ),
            let rightShape = mappedShape(
                brow: rightBrow,
                eye: rightEyeInfo,
                nostrilPair: (innerLeftNostril, innerRightNostril),
                faceCenterX: faceCenterX,
                faceRect: faceRect,
                imageSize: imageSize,
                viewSize: viewSize
            )
        else {
            return nil
        }

        return BrowOverlayGeometry(
            leftStencil: leftShape.stencil,
            rightStencil: rightShape.stencil,
            leftCenterline: leftShape.centerline,
            rightCenterline: rightShape.centerline,
            guideLines: leftShape.guides + rightShape.guides,
            horizontalGuideLine: horizontalGuide(
                leftStartTop: leftShape.startGuideTop,
                rightStartTop: rightShape.startGuideTop,
                leftTailPoint: leftShape.tailPoint,
                rightTailPoint: rightShape.tailPoint
            )
        )
    }

    private static func mappedShape(
        brow: [CGPoint],
        eye: EyeInfo,
        nostrilPair: (CGPoint, CGPoint),
        faceCenterX: CGFloat,
        faceRect: CGRect,
        imageSize: CGSize,
        viewSize: CGSize
    ) -> BrowShape? {
        let browCenterX = brow.map(\.x).reduce(0, +) / CGFloat(Swift.max(brow.count, 1))
        let nostrilOuter = browCenterX < faceCenterX ? nostrilPair.0 : nostrilPair.1

        let startIntersection = PolylineMath.verticalIntersection(x: nostrilOuter.x, with: brow) ?? brow.closestPoint(toX: nostrilOuter.x)

        let irisOuter = eye.outerIrisEdge
        let archIntersection = PolylineMath.rayIntersection(from: nostrilOuter, toward: irisOuter, with: brow) ?? brow.closestPoint(to: eye.outerUpperGuideTarget)
        let tailIntersection = PolylineMath.rayIntersection(from: nostrilOuter, toward: eye.outerCorner, with: brow) ?? brow.farthestFrom(point: startIntersection)

        let trimmed = brow.trimmedBetweenX(startIntersection.x, and: tailIntersection.x)
        guard trimmed.count >= 2 else { return nil }

        var centerline = PolylineMath.resample(points: trimmed, count: 26)
        centerline = centerline.reanchored(start: startIntersection, arch: archIntersection, tail: tailIntersection)

        let eyeGap = max(eye.topY - archIntersection.y, 8)
        let faceWidth = faceRect.width
        let baseThickness = max(min(eyeGap * 0.42, faceWidth * 0.035), 8)

        let stencil = PolylineMath.makeStencil(
            around: centerline,
            baseThickness: baseThickness
        )

        let guideExtension = max(faceRect.width * 0.03, 12)

        let startTop = CGPoint(x: startIntersection.x, y: startIntersection.y - guideExtension)
        let archTop = archIntersection + (archIntersection - nostrilOuter).normalized * guideExtension
        let tailTop = tailIntersection + (tailIntersection - nostrilOuter).normalized * guideExtension

        let guidesInView = [
            [nostrilOuter, startTop],
            [nostrilOuter, archTop],
            [nostrilOuter, tailTop]
        ].map { line in
            line.map { imagePoint in
                imagePoint.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true)
            }
        }

        return BrowShape(
            stencil: stencil.map { $0.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true) },
            centerline: centerline.map { $0.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true) },
            guides: guidesInView,
            startGuideTop: startTop.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true),
            tailPoint: tailIntersection.aspectFillMapped(from: imageSize, into: viewSize, mirroredHorizontally: true)
        )
    }

    private static func horizontalGuide(
        leftStartTop: CGPoint,
        rightStartTop: CGPoint,
        leftTailPoint: CGPoint,
        rightTailPoint: CGPoint
    ) -> [CGPoint] {
        let y = ((leftStartTop.y + rightStartTop.y) * 0.5) - 6
        let leftPoint = CGPoint(x: Swift.min(leftTailPoint.x, rightTailPoint.x), y: y)
        let rightPoint = CGPoint(x: Swift.max(leftTailPoint.x, rightTailPoint.x), y: y)

        return [leftPoint, rightPoint]
    }
}

private struct EyeInfo {
    let points: [CGPoint]
    let pupil: CGPoint?
    let faceCenterX: CGFloat

    var outerCorner: CGPoint {
        if center.x < faceCenterX {
            return points.min(by: { $0.x < $1.x }) ?? .zero
        } else {
            return points.max(by: { $0.x < $1.x }) ?? .zero
        }
    }

    var innerCorner: CGPoint {
        if center.x < faceCenterX {
            return points.max(by: { $0.x < $1.x }) ?? .zero
        } else {
            return points.min(by: { $0.x < $1.x }) ?? .zero
        }
    }

    var topY: CGFloat {
        points.map(\.y).min() ?? 0
    }

    var center: CGPoint {
        pupil ?? CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(max(points.count, 1)),
            y: points.map(\.y).reduce(0, +) / CGFloat(max(points.count, 1))
        )
    }

    var width: CGFloat {
        (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
    }

    var outerIrisEdge: CGPoint {
        let direction = (outerCorner - center).normalized
        let irisRadius = max(width * 0.16, 3)
        return center + direction * irisRadius
    }

    var outerUpperGuideTarget: CGPoint {
        CGPoint(x: outerCorner.x, y: topY)
    }
}

private struct BrowShape {
    let stencil: [CGPoint]
    let centerline: [CGPoint]
    let guides: [[CGPoint]]
    let startGuideTop: CGPoint
    let tailPoint: CGPoint
}

private struct BrowOverlayGeometry {
    let leftStencil: [CGPoint]
    let rightStencil: [CGPoint]
    let leftCenterline: [CGPoint]
    let rightCenterline: [CGPoint]
    let guideLines: [[CGPoint]]
    let horizontalGuideLine: [CGPoint]

    func blended(with previous: BrowOverlayGeometry, alpha: CGFloat) -> BrowOverlayGeometry {
        let horizontalAlpha = alpha * 0.45
        return BrowOverlayGeometry(
            leftStencil: blend(points: leftStencil, with: previous.leftStencil, alpha: alpha),
            rightStencil: blend(points: rightStencil, with: previous.rightStencil, alpha: alpha),
            leftCenterline: blend(points: leftCenterline, with: previous.leftCenterline, alpha: alpha),
            rightCenterline: blend(points: rightCenterline, with: previous.rightCenterline, alpha: alpha),
            guideLines: zip(guideLines, previous.guideLines).map { current, prior in
                blend(points: current, with: prior, alpha: alpha)
            },
            horizontalGuideLine: blend(points: horizontalGuideLine, with: previous.horizontalGuideLine, alpha: horizontalAlpha)
        )
    }

    private func blend(points: [CGPoint], with previous: [CGPoint], alpha: CGFloat) -> [CGPoint] {
        guard points.count == previous.count else { return points }
        return zip(points, previous).map { current, prior in
            CGPoint(
                x: prior.x + (current.x - prior.x) * alpha,
                y: prior.y + (current.y - prior.y) * alpha
            )
        }
    }
}

private final class BrowOverlaySmoother {
    private let alpha: CGFloat
    private var previous: BrowOverlayGeometry?

    init(alpha: CGFloat) {
        self.alpha = alpha
    }

    func smoothed(with current: BrowOverlayGeometry) -> BrowOverlayGeometry {
        guard let previous else {
            self.previous = current
            return current
        }

        let blended = current.blended(with: previous, alpha: alpha)
        self.previous = blended
        return blended
    }

    func reset() {
        previous = nil
    }
}

private enum PolylineMath {
    static func verticalIntersection(x: CGFloat, with polyline: [CGPoint]) -> CGPoint? {
        let intersections = zip(polyline, polyline.dropFirst()).compactMap { p1, p2 -> CGPoint? in
            guard x >= min(p1.x, p2.x), x <= max(p1.x, p2.x), p1.x != p2.x else { return nil }
            let t = (x - p1.x) / (p2.x - p1.x)
            return p1 + (p2 - p1) * t
        }

        return intersections.sorted(by: { $0.y < $1.y }).first
    }

    static func rayIntersection(from origin: CGPoint, toward target: CGPoint, with polyline: [CGPoint]) -> CGPoint? {
        let ray = target - origin
        guard ray.length > 0 else { return nil }

        let intersections = zip(polyline, polyline.dropFirst()).compactMap { p1, p2 -> (CGPoint, CGFloat)? in
            let segment = p2 - p1
            let denominator = cross(ray, segment)
            guard abs(denominator) > 0.0001 else { return nil }

            let offset = p1 - origin
            let t = cross(offset, segment) / denominator
            let u = cross(offset, ray) / denominator

            guard t >= 0, (0...1).contains(u) else { return nil }
            return (origin + ray * t, t)
        }

        return intersections.min(by: { $0.1 < $1.1 })?.0
    }

    static func resample(points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > 1, count > 1 else { return points }

        var cumulative: [CGFloat] = [0]
        for (p1, p2) in zip(points, points.dropFirst()) {
            cumulative.append(cumulative.last! + (p2 - p1).length)
        }

        let totalLength = cumulative.last ?? 0
        guard totalLength > 0 else { return Array(repeating: points[0], count: count) }

        var result: [CGPoint] = []
        var segmentIndex = 0

        for step in 0..<count {
            let distance = totalLength * CGFloat(step) / CGFloat(count - 1)

            while segmentIndex < cumulative.count - 2, cumulative[segmentIndex + 1] < distance {
                segmentIndex += 1
            }

            let start = points[segmentIndex]
            let end = points[segmentIndex + 1]
            let segmentStart = cumulative[segmentIndex]
            let segmentEnd = cumulative[segmentIndex + 1]
            let segmentLength = max(segmentEnd - segmentStart, 0.0001)
            let t = (distance - segmentStart) / segmentLength
            result.append(start + (end - start) * t)
        }

        return result
    }

    static func makeStencil(around centerline: [CGPoint], baseThickness: CGFloat) -> [CGPoint] {
        guard centerline.count >= 2 else { return centerline }

        var upper: [CGPoint] = []
        var lower: [CGPoint] = []

        for index in centerline.indices {
            let point = centerline[index]
            let previous = centerline[max(index - 1, 0)]
            let next = centerline[min(index + 1, centerline.count - 1)]
            let tangent = (next - previous).normalized

            let candidateA = CGPoint(x: -tangent.y, y: tangent.x)
            let candidateB = CGPoint(x: tangent.y, y: -tangent.x)
            let upperNormal = candidateA.y < candidateB.y ? candidateA : candidateB
            let lowerNormal = upperNormal * -1

            let t = CGFloat(index) / CGFloat(centerline.count - 1)
            let thickness = taperedThickness(base: baseThickness, t: t)

            upper.append(point + upperNormal * (thickness * 0.56))
            lower.append(point + lowerNormal * (thickness * 0.44))
        }

        return upper + lower.reversed()
    }

    private static func taperedThickness(base: CGFloat, t: CGFloat) -> CGFloat {
        let inner = base * (1.0 - 0.12 * min(t / 0.45, 1))
        let tailStart = CGFloat(0.68)
        if t <= tailStart { return inner }

        let tailT = (t - tailStart) / (1 - tailStart)
        return inner + (base * 0.38 - inner) * tailT
    }

    private static func cross(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        lhs.x * rhs.y - lhs.y * rhs.x
    }
}

private extension VNFaceLandmarkRegion2D {
    func imagePoints(in face: VNFaceObservation, imageSize: CGSize) -> [CGPoint] {
        normalizedPoints.map { point in
            let normalizedX = face.boundingBox.origin.x + CGFloat(point.x) * face.boundingBox.width
            let normalizedY = face.boundingBox.origin.y + CGFloat(point.y) * face.boundingBox.height
            return CGPoint(
                x: normalizedX * imageSize.width,
                y: (1 - normalizedY) * imageSize.height
            )
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }
}

private extension CGRect {
    func imageRect(in imageSize: CGSize) -> CGRect {
        CGRect(
            x: origin.x * imageSize.width,
            y: (1 - origin.y - height) * imageSize.height,
            width: width * imageSize.width,
            height: height * imageSize.height
        )
    }
}

private extension Array where Element == CGPoint {
    func sortedByX() -> [CGPoint] {
        sorted(by: { $0.x < $1.x })
    }

    func filteredLowerHalf() -> [CGPoint] {
        let medianY = map(\.y).reduce(0, +) / CGFloat(Swift.max(count, 1))
        return filter { $0.y >= medianY }
    }

    func closestPoint(toX x: CGFloat) -> CGPoint {
        self.min(by: { abs($0.x - x) < abs($1.x - x) }) ?? .zero
    }

    func closestPoint(to point: CGPoint) -> CGPoint {
        self.min(by: { ($0 - point).length < ($1 - point).length }) ?? .zero
    }

    func farthestFrom(point: CGPoint) -> CGPoint {
        self.max(by: { ($0 - point).length < ($1 - point).length }) ?? .zero
    }

    func trimmedBetweenX(_ x1: CGFloat, and x2: CGFloat) -> [CGPoint] {
        let minX = Swift.min(x1, x2)
        let maxX = Swift.max(x1, x2)

        var result = filter { $0.x >= minX && $0.x <= maxX }
        result.append(closestPoint(toX: minX))
        result.append(closestPoint(toX: maxX))
        return result.sortedByX()
    }

    func reanchored(start: CGPoint, arch: CGPoint, tail: CGPoint) -> [CGPoint] {
        guard count > 2 else { return self }

        let startIndex = 0
        let tailIndex = count - 1
        let archIndex = map(\.y).enumerated().min(by: { $0.element < $1.element })?.offset ?? count / 2

        let startDelta = start - self[startIndex]
        let archDelta = arch - self[archIndex]
        let tailDelta = tail - self[tailIndex]

        return enumerated().map { index, point in
            let influence: CGPoint
            if index <= archIndex {
                let t = CGFloat(index - startIndex) / CGFloat(Swift.max(archIndex - startIndex, 1))
                influence = startDelta * (1 - t) + archDelta * t
            } else {
                let t = CGFloat(index - archIndex) / CGFloat(Swift.max(tailIndex - archIndex, 1))
                influence = archDelta * (1 - t) + tailDelta * t
            }
            return point + influence
        }
    }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    var length: CGFloat {
        sqrt(x * x + y * y)
    }

    var normalized: CGPoint {
        let len = max(length, 0.0001)
        return CGPoint(x: x / len, y: y / len)
    }

    func aspectFillMapped(from imageSize: CGSize, into viewSize: CGSize, mirroredHorizontally: Bool = false) -> CGPoint {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let xOffset = (viewSize.width - scaledSize.width) * 0.5
        let yOffset = (viewSize.height - scaledSize.height) * 0.5

        var point = CGPoint(
            x: x * scale + xOffset,
            y: y * scale + yOffset
        )

        if mirroredHorizontally {
            point.x = viewSize.width - point.x
        }

        return point
    }
}

private extension UIBezierPath {
    convenience init(polyline: [CGPoint]) {
        self.init()
        guard let first = polyline.first else { return }
        move(to: first)
        polyline.dropFirst().forEach(addLine(to:))
    }

    convenience init(closedPolygon: [CGPoint]) {
        self.init(polyline: closedPolygon)
        close()
    }
}
