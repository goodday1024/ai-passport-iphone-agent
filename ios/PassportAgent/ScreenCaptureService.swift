import CoreImage
@preconcurrency import ScreenCaptureKit
import UIKit

final class ScreenCaptureService: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "cn.folotoy.passport.capture")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var latestJPEG: Data?
    private var frameSequence: UInt64 = 0
    var onStatus: (@Sendable (String) -> Void)?

    override init() {
        super.init()
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
    }

    @MainActor func presentPicker() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        picker.present()
    }

    func stop() async {
        await MainActor.run { SCContentSharingPicker.shared.isActive = false }
        if let stream { try? await stream.stopCapture() }
        self.stream = nil
        queue.sync { latestJPEG = nil }
        onStatus?("未共享")
    }

    func frame() -> Data? { queue.sync { latestJPEG } }

    func snapshot() -> (data: Data, sequence: UInt64)? {
        queue.sync { latestJPEG.map { ($0, frameSequence) } }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in picker.isActive = false }
        onStatus?("用户取消")
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task {
            await MainActor.run { picker.isActive = false }
            await start(filter: filter)
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in SCContentSharingPicker.shared.isActive = false }
        onStatus?("启动失败：\(error.localizedDescription)")
    }

    private func start(filter: SCContentFilter) async {
        if stream != nil { await stop() }
        let config = SCStreamConfiguration()
        config.width = 768
        config.height = 1366
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await newStream.startCapture()
            stream = newStream
            onStatus?("共享中")
        } catch { onStatus?("采集失败：\(error.localizedDescription)") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.55]) else { return }
        latestJPEG = jpeg
        frameSequence &+= 1
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        self.stream = nil
        queue.sync { latestJPEG = nil }
        onStatus?("已停止：\(error.localizedDescription)")
    }
}
