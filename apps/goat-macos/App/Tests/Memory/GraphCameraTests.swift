import Foundation
import Testing

@testable import Bleet
@testable import GOAT
@testable import Inference

extension AppTests.Memory {
    @Suite struct GraphCameraTests {

        @Test func cameraZoomKeepsPointerAnchorStableAndClampsExtremes() {
            var camera = GraphCamera()
            let size = CGSize(width: 800, height: 400)
            let anchor = CGPoint(x: 500, y: 300)
            camera.scale(to: 2, anchor: anchor, size: size)
            #expect(camera.zoom == 2)
            #expect(camera.pan == CGSize(width: -100, height: -100))
            camera.scale(to: 1, anchor: anchor, size: size)
            #expect(camera.pan == .zero)
            camera.scale(to: 100, anchor: anchor, size: size)
            #expect(camera.zoom == GraphCamera.maximumZoom)
            camera.scale(to: -100, anchor: anchor, size: size)
            #expect(camera.zoom == GraphCamera.minimumZoom)
            camera.move(to: CGSize(width: 1e9, height: -1e9), size: size)
            #expect(camera.pan == CGSize(width: 3200, height: -1600))
        }

        @Test func cameraRejectsNonFiniteInputsAndBoundsRotation() {
            var camera = GraphCamera()
            let size = CGSize(width: 800, height: 400)
            camera.scale(to: .infinity, anchor: .zero, size: size)
            camera.scale(to: 2, anchor: .zero, size: .zero)
            camera.move(to: CGSize(width: CGFloat.nan, height: 1), size: size)
            camera.move(to: .zero, size: CGSize(width: CGFloat.infinity, height: 400))
            camera.orbit(horizontal: .nan, vertical: 0)
            #expect(camera == GraphCamera())
            camera.orbit(horizontal: .pi * 21, vertical: 0)
            #expect(abs(camera.yaw - .pi) < 0.00001)
        }

        @Test func cameraWheelZoomIsGradualReversibleAndSupportsCloseInspection() {
            var camera = GraphCamera()
            let size = CGSize(width: 800, height: 400)
            let anchor = CGPoint(x: 780, y: 380)
            camera.scroll(delta: 20, precise: true, anchor: anchor, size: size)
            #expect(camera.zoom > 1 && camera.zoom < 1.07)
            camera.scroll(delta: -20, precise: true, anchor: anchor, size: size)
            #expect(abs(camera.zoom - 1) < 0.00001)
            #expect(abs(camera.pan.width) < 0.00001)
            camera.scroll(delta: 1e9, precise: false, anchor: anchor, size: size)
            #expect(camera.zoom < 1.23)
            camera = GraphCamera()
            camera.scale(to: 20, anchor: anchor, size: size)
            #expect(camera.zoom == 20)
            // Close zoom must preserve the pointer anchor beyond the old four-viewport pan limit.
            #expect(camera.pan == CGSize(width: -7220, height: -3420))
            camera.scale(to: 1, anchor: anchor, size: size)
            #expect(abs(camera.pan.width) < 0.00001)
            #expect(abs(camera.pan.height) < 0.00001)
            camera.scroll(delta: .infinity, precise: true, anchor: anchor, size: size)
            #expect(camera.zoom == 1)
        }
    }
}
