//
//  MotionJPEGConvertTests.swift
//  MotionJPEGConvertTests
//
//  Created by 李龙宇 on 2024/12/3.
//

import Testing
import CoreGraphics
@testable import MotionJPEGConvert

struct MotionJPEGConvertTests {

    @Test func portraitVideoGeometryIsNormalized() {
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let result = Converter.normalizedVideoGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: transform
        )

        #expect(result.renderSize == CGSize(width: 1080, height: 1920))
        let bounds = CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080))
            .applying(result.transform)
        #expect(abs(bounds.minX) < 0.001)
        #expect(abs(bounds.minY) < 0.001)
    }

    @Test func upsideDownVideoGeometryIsNormalized() {
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        let result = Converter.normalizedVideoGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: transform
        )

        #expect(result.renderSize == CGSize(width: 1920, height: 1080))
        let bounds = CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080))
            .applying(result.transform)
        #expect(abs(bounds.minX) < 0.001)
        #expect(abs(bounds.minY) < 0.001)
    }

    @Test func presentationTimestampIsClampedToVideoDuration() {
        let duration = CMTime(seconds: 3, preferredTimescale: 600)
        #expect(Converter.presentationTimestampMicroseconds(
            CMTime(seconds: 1.5, preferredTimescale: 600),
            duration: duration
        ) == 1_500_000)
        #expect(Converter.presentationTimestampMicroseconds(
            CMTime(seconds: 4, preferredTimescale: 600),
            duration: duration
        ) == 3_000_000)
    }

    @Test func motionPhotoPresentationTimestampCanBeParsedFromXMP() {
        let xmp = """
        <GCamera:MicroVideoPresentationTimestampUs>1500000</GCamera:MicroVideoPresentationTimestampUs>
        """
        let time = Converter.motionPhotoPresentationTime(fromJPEGData: Data(xmp.utf8))
        #expect(time?.seconds == 1.5)
    }

}
