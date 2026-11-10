import SwiftUI
import MediaPlayer
import UIKit

struct AudioControlsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var calls = CallStateMonitor.shared

    private var callTitle: String {
        switch calls.state {
        case .inactive: return "系统通话：无通话"
        case .ringing: return "来电中"
        case .dialing: return "呼叫中"
        case .active: return "正在通话"
        case .held: return "通话保留"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("导航播报音量")
                Spacer()
                Text("\(Int((SpeechVolumePolicy.normalized(settings.navVoiceVolume) * 100).rounded()))%")
                    .monospacedDigit().foregroundColor(AppPalette.secondary)
                    .accessibilityIdentifier("audio.navigation.volume.value")
            }
            Slider(value: $settings.navVoiceVolume, in: 0...1, step: 0.05)
                .accessibilityLabel("导航播报音量")
                .accessibilityIdentifier("audio.navigation.volume")
            Text("系统媒体音量")
            SystemMediaVolumeView()
                .frame(height: 40)
                .accessibilityLabel("系统媒体音量")
            Label(callTitle, systemImage: "waveform")
                .font(.footnote)
                .foregroundColor(calls.state.isInCall ? AppPalette.warning : AppPalette.secondary)
                .accessibilityIdentifier("audio.call.status")
            if calls.state.isInCall {
                Text("导航播报已暂停").font(.caption).foregroundColor(AppPalette.secondary)
            }
        }
    }
}

/// The system owns this slider and its routing behavior; no programmatic volume
/// writes or private controls for other applications are used.
private struct SystemMediaVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = UIColor(AppPalette.accent)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
