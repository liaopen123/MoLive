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

}
