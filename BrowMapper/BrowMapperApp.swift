//
//  BrowMapperApp.swift
//  BrowMapper
//
//  Created by Stephanie Bassock on 2/17/26.
//

import SwiftUI
import AVFoundation
import Vision
import Combine

// MARK: - 1. Camera and Vision Service

class CameraViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    
    // Callback to send detected landmarks back to the ViewModel
    var onFacesDetected: ((VNFaceObservation?, CGSize) -> Void)?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: frontCamera) else { return }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }
        
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        
        self.previewLayer = preview
        self.captureSession = session
        
        // Start session on a background thread
        DispatchQueue.global(qos: .background).async {
            session.startRunning()
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let self = self,
                  let results = request.results as? [VNFaceObservation],
                  let face = results.first else {
                self?.onFacesDetected?(nil, .zero)
                return
            }
            
            // We need the dimension of the underlying image buffers to normalize coordinates later
            let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            self.onFacesDetected?(face, imageSize)
        }
        
        try? imageRequestHandler.perform([faceLandmarksRequest])
    }
}

// SwiftUI wrapper for the CameraViewController
struct CameraPreview: UIViewControllerRepresentable {
    @ObservedObject var viewModel: EyebrowMappingViewModel
    
    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.onFacesDetected = { observation, size in
            DispatchQueue.main.async {
                self.viewModel.updateLandmarks(observation: observation, imageSize: size)
            }
        }
        return controller
    }
    
    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

// MARK: - 2. View Model

// A struct to hold the normalized points relevant to eyebrow mapping
struct MappingPoints {
    let leftBrowInner: CGPoint
    let leftBrowPeak: CGPoint
    let leftBrowOuter: CGPoint
    let rightBrowInner: CGPoint
    let rightBrowPeak: CGPoint
    let rightBrowOuter: CGPoint
    let noseLeft: CGPoint
    let noseRight: CGPoint
    let leftPupil: CGPoint
    let rightPupil: CGPoint
    let medianLineTop: CGPoint // Top of nose bridge
}

class EyebrowMappingViewModel: ObservableObject {
    @Published var currentMappingPoints: MappingPoints?
    @Published var sourceImageSize: CGSize = .zero
    
    func updateLandmarks(observation: VNFaceObservation?, imageSize: CGSize) {
        self.sourceImageSize = imageSize
        
        guard let face = observation, let landmarks = face.landmarks else {
            self.currentMappingPoints = nil
            return
        }
        
        // Helper to extract a specific point from a landmark region
        func getPoint(_ region: VNFaceLandmarkRegion2D?, index: Int) -> CGPoint? {
            guard let region = region, index < region.pointCount else { return nil }
            // Vision points are normalized relative to the bounding box of the face.
            // We need to convert them to be normalized relative to the whole screen.
            let point = region.normalizedPoints[index]
            let x = face.boundingBox.origin.x + point.x * face.boundingBox.size.width
            let y = face.boundingBox.origin.y + point.y * face.boundingBox.size.height
            return CGPoint(x: x, y: y)
        }

        // Extract key points based on standard Vision landmark indices
        guard let leftBrowInner = getPoint(landmarks.leftEyebrow, index: 0),
              // Peak is roughly in the middle-ish index
              let leftBrowPeak = getPoint(landmarks.leftEyebrow, index: (landmarks.leftEyebrow?.pointCount ?? 0) / 2),
              let leftBrowOuter = getPoint(landmarks.leftEyebrow, index: (landmarks.leftEyebrow?.pointCount ?? 1) - 1),
              
              let rightBrowInner = getPoint(landmarks.rightEyebrow, index: (landmarks.rightEyebrow?.pointCount ?? 1) - 1),
              let rightBrowPeak = getPoint(landmarks.rightEyebrow, index: (landmarks.rightEyebrow?.pointCount ?? 0) / 2),
              let rightBrowOuter = getPoint(landmarks.rightEyebrow, index: 0),
              
              // Nose flares are usually at the end of the noseIndents or noseCrest indices depending on OS version, using simplified outer nose here.
              let nose = landmarks.nose, nose.pointCount > 0,
              let noseLeft = getPoint(nose, index: 0),
              let noseRight = getPoint(nose, index: nose.pointCount - 1),
              let medianTop = getPoint(landmarks.medianLine, index: 0),
              
              let leftPupil = getPoint(landmarks.leftPupil, index: 0),
              let rightPupil = getPoint(landmarks.rightPupil, index: 0)
        else {
            self.currentMappingPoints = nil
            return
        }
        
        self.currentMappingPoints = MappingPoints(
            leftBrowInner: leftBrowInner, leftBrowPeak: leftBrowPeak, leftBrowOuter: leftBrowOuter,
            rightBrowInner: rightBrowInner, rightBrowPeak: rightBrowPeak, rightBrowOuter: rightBrowOuter,
            noseLeft: noseLeft, noseRight: noseRight,
            leftPupil: leftPupil, rightPupil: rightPupil,
            medianLineTop: medianTop
        )
    }
}

// MARK: - 3. SwiftUI Views

struct ContentView: View {
    @StateObject private var viewModel = EyebrowMappingViewModel()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Layer 1: Camera Feed
                CameraPreview(viewModel: viewModel)
                    .ignoresSafeArea()
                
                // Layer 2: The Mapping Overlay
                if let points = viewModel.currentMappingPoints {
                    MappingOverlayView(points: points, imageSize: viewModel.sourceImageSize, screenSize: geometry.size)
                        .ignoresSafeArea()
                } else {
                    Text("Align your face")
                        .foregroundColor(.white)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(10)
                }
            }
        }
    }
}

struct MappingOverlayView: View {
    let points: MappingPoints
    let imageSize: CGSize
    let screenSize: CGSize
    
    // Helper to convert Vision normalized coordinates (0.0-1.0, origin bottom-left)
    // to SwiftUI screen coordinates (pixels, origin top-left)
    func convert(_ normalizedPoint: CGPoint) -> CGPoint {
        // 1. Flip Y axis (Vision is bottom-left origin, SwiftUI is top-left)
        let flippedY = 1.0 - normalizedPoint.y
        
        // 2. Scale to screen dimensions.
        // Note: This assumes AspectFill behavior in the camera preview.
        // A more robust solution involves calculating the exact aspect ratio scaling,
        // but this works reasonably well for standard full-screen phone layouts.
        let x = normalizedPoint.x * screenSize.width
        let y = flippedY * screenSize.height
        
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        Canvas { context, size in
            // Define line styles
            let purpleStyle = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5])
            let redStyle = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5])
            let brownStyle = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5])
            
            // --- Draw Purple Diagonals ---
            
            // Left Side: Nose -> Outer Eye -> Outer Brow
            var pPath1 = Path()
            pPath1.move(to: convert(points.noseLeft))
            pPath1.addLine(to: convert(points.leftBrowOuter))
            context.stroke(pPath1, with: .color(.purple), style: purpleStyle)

            // Left Side: Nose -> Pupil -> Peak
            // To draw a line *through* the pupil to the peak, we draw from nose to peak
            var pPath2 = Path()
            pPath2.move(to: convert(points.noseLeft))
            pPath2.addLine(to: convert(points.leftBrowPeak))
            context.stroke(pPath2, with: .color(.purple), style: purpleStyle)

            // Left Side: Nose -> Inner Eye -> Inner Brow (Approximated using inner brow)
            var pPath3 = Path()
            pPath3.move(to: convert(points.noseLeft))
            pPath3.addLine(to: convert(points.leftBrowInner))
            context.stroke(pPath3, with: .color(.purple), style: purpleStyle)
            
            // (Repeat for right side - simplified for brevity in canvas, mirroring logic)
             var pPath4 = Path()
             pPath4.move(to: convert(points.noseRight)); pPath4.addLine(to: convert(points.rightBrowOuter))
             context.stroke(pPath4, with: .color(.purple), style: purpleStyle)
            
             var pPath5 = Path()
             pPath5.move(to: convert(points.noseRight)); pPath5.addLine(to: convert(points.rightBrowPeak))
             context.stroke(pPath5, with: .color(.purple), style: purpleStyle)
            
            var pPath6 = Path()
            pPath6.move(to: convert(points.noseRight)); pPath6.addLine(to: convert(points.rightBrowInner))
            context.stroke(pPath6, with: .color(.purple), style: purpleStyle)


            // --- Draw Red Verticals ---
            
            // Inner brow verticals
            let leftInnerX = convert(points.leftBrowInner).x
            var rPath1 = Path()
            rPath1.move(to: CGPoint(x: leftInnerX, y: 0))
            rPath1.addLine(to: CGPoint(x: leftInnerX, y: size.height))
            context.stroke(rPath1, with: .color(.red), style: redStyle)
            
            let rightInnerX = convert(points.rightBrowInner).x
            var rPath2 = Path()
            rPath2.move(to: CGPoint(x: rightInnerX, y: 0))
            rPath2.addLine(to: CGPoint(x: rightInnerX, y: size.height))
            context.stroke(rPath2, with: .color(.red), style: redStyle)
            
            // Center nose verticals (approximated using median line top)
            let centerX = convert(points.medianLineTop).x
            // Offset slightly to match the image's bridge width
            let bridgeOffset: CGFloat = 15
            var rPath3 = Path()
            rPath3.move(to: CGPoint(x: centerX - bridgeOffset, y: 0))
            rPath3.addLine(to: CGPoint(x: centerX - bridgeOffset, y: size.height))
            context.stroke(rPath3, with: .color(.red), style: redStyle)
            
            var rPath4 = Path()
            rPath4.move(to: CGPoint(x: centerX + bridgeOffset, y: 0))
            rPath4.addLine(to: CGPoint(x: centerX + bridgeOffset, y: size.height))
            context.stroke(rPath4, with: .color(.red), style: redStyle)


            // --- Draw Brown Horizontals ---
            
            // Top of inner brows
            let topY = min(convert(points.leftBrowInner).y, convert(points.rightBrowInner).y)
            var bPath1 = Path()
            bPath1.move(to: CGPoint(x: 0, y: topY))
            bPath1.addLine(to: CGPoint(x: size.width, y: topY))
            context.stroke(bPath1, with: .color(.brown), style: brownStyle)

            // Bottom of inner brows (approximated offset)
            let bottomY = topY + 30 // Arbitrary height for brow thickness based on image
            var bPath2 = Path()
            bPath2.move(to: CGPoint(x: 0, y: bottomY))
            bPath2.addLine(to: CGPoint(x: size.width, y: bottomY))
            context.stroke(bPath2, with: .color(.brown), style: brownStyle)
        }
    }
}

// Basic entry point
@main
struct EyebrowApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
