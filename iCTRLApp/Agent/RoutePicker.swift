import AVKit
import SwiftUI

/// 音声の出力先を選ぶ、システムのボタン（AirPods、スピーカー、AirPlay など）。
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
