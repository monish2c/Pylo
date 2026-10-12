import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import FragmentedMP4

// VideoToolbox invokes its callback on an encoder-owned thread. All mutable
// results are protected by this lock; buffers are immutable after delivery.
private final class EncoderOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var buffers: [CMSampleBuffer] = []
  private var statuses: [OSStatus] = []

  func append(_ buffer: CMSampleBuffer?, status: OSStatus) {
    lock.lock()
    defer { lock.unlock() }
    statuses.append(status)
    if let buffer { buffers.append(buffer) }
  }

  var result: ([CMSampleBuffer], [OSStatus]) {
    lock.lock()
    defer { lock.unlock() }
    return (buffers, statuses)
  }
}

@Suite("HEVC Recording")
struct HEVCRecordingTests {
  @Test("Producer reference time uses zero flags and big-endian NTP and media clocks")
  func producerReferenceTime() {
    let box = FragmentedMP4Writer.producerReferenceTimeBox(
      date: Date(timeIntervalSince1970: 0.5), mediaTime: 0x1234_5678_9ABC_DEF0)
    #expect(
      box
        == Data([
          0, 0, 0, 32, 0x70, 0x72, 0x66, 0x74, 1, 0, 0, 0,
          0, 0, 0, 1, 0x83, 0xAA, 0x7E, 0x80, 0x80, 0, 0, 0,
          0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        ]))
  }
  @Test("Real 4K HEVC frames survive MP4 packaging and decoding")
  func roundTrip4K() async throws {
    let output = EncoderOutput()
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: nil, width: 3840, height: 2160, codecType: kCMVideoCodecType_HEVC,
      encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: { refcon, _, status, _, buffer in
        guard let refcon else { return }
        Unmanaged<EncoderOutput>.fromOpaque(refcon).takeUnretainedValue().append(
          buffer, status: status)
      },
      refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &session)
    try #require(status == noErr)
    let encoder = try #require(session)
    defer { VTCompressionSessionInvalidate(encoder) }
    try #require(
      VTSessionSetProperty(
        encoder, key: kVTCompressionPropertyKey_ProfileLevel,
        value: kVTProfileLevel_HEVC_Main_AutoLevel) == noErr)
    try #require(
      VTSessionSetProperty(
        encoder, key: kVTCompressionPropertyKey_AllowFrameReordering,
        value: kCFBooleanFalse) == noErr)

    var pixelBuffer: CVPixelBuffer?
    try #require(
      CVPixelBufferCreate(
        nil, 3840, 2160, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == noErr)
    let pixels = try #require(pixelBuffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
      let address = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
      memset(
        address, plane == 0 ? 80 : 128,
        CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
          * CVPixelBufferGetHeightOfPlane(pixels, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    for frame in 0..<3 {
      try #require(
        VTCompressionSessionEncodeFrame(
          encoder, imageBuffer: pixels,
          presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30),
          duration: CMTime(value: 1, timescale: 30), frameProperties: nil,
          sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr)
    }
    try #require(
      VTCompressionSessionCompleteFrames(
        encoder, untilPresentationTimeStamp: .positiveInfinity) == noErr)
    let (samples, errors) = output.result
    try #require(samples.count == 3)
    #expect(errors.allSatisfy { $0 == noErr })

    let writer = FragmentedMP4Writer()
    for sample in samples { writer.appendVideoSample(sample) }
    let initialization = try #require(writer.initSegment)
    #expect(initialization.range(of: Data("hvc1".utf8)) != nil)
    #expect(initialization.range(of: Data("hvcC".utf8)) != nil)
    #expect(initialization.range(of: Data("avcC".utf8)) == nil)
    writer.stop()
    let fragment = try #require(writer.ringBuffer.snapshot().first)
    #expect(fragment.data.subdata(in: 4..<8) == Data("prft".utf8))
    #expect(fragment.data.subdata(in: 8..<12) == Data([1, 0, 0, 0]))

    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("pylo-hevc-\(UUID()).mp4")
    defer { try? FileManager.default.removeItem(at: file) }
    try (initialization + fragment.data).write(to: file)
    let asset = AVURLAsset(url: file)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let decoded = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(decoded)
    try #require(reader.startReading())
    var frameCount = 0
    while let sample = decoded.copyNextSampleBuffer() {
      let pixels = try #require(sample.imageBuffer)
      #expect(CVPixelBufferGetWidth(pixels) == 3840)
      #expect(CVPixelBufferGetHeight(pixels) == 2160)
      frameCount += 1
    }
    #expect(frameCount == 3)
    #expect(reader.status == .completed)
  }
}
