import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MindropVoiceWidgetBundle: WidgetBundle {
    var body: some Widget {
        MindropQuickVoiceLiveActivity()
        if #available(iOS 18.0, *) {
            MindropQuickVoiceControl()
        }
    }
}

struct MindropQuickVoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MindropQuickVoiceActivityAttributes.self) { context in
            MindropQuickVoiceLockScreenView(context: context)
                .activityBackgroundTint(Color.mindropActivityBackground)
                .activitySystemActionForegroundColor(.mindropAccent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        MindropWidgetIcon(size: 22)
                        Text(leadingTitle(for: context.state.phase))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    MindropLiveActivityAction(context: context, isCompact: false)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    MindropExpandedVoiceContent(state: context.state)
                }
            } compactLeading: {
                MindropWidgetIcon(size: 19)
            } compactTrailing: {
                MindropCompactStatusView(state: context.state)
            } minimal: {
                MindropWidgetIcon(size: 16)
            }
            .keylineTint(.mindropAccent)
        }
    }

    private func leadingTitle(for phase: MindropQuickVoicePhase) -> String {
        switch phase {
        case .recording:
            "小落在听"
        case .processing:
            "处理中"
        case .completed:
            "已完成"
        case .failed:
            "未完成"
        case .permissionDenied:
            "需要授权"
        }
    }
}

@available(iOS 18.0, *)
struct MindropQuickVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.mindrop.ios.quickVoiceControl") {
            ControlWidgetButton(action: MindropQuickVoiceProbeIntent()) {
                Label("侧键诊断", systemImage: "waveform")
            }
            .tint(.mindropAccent)
        }
        .displayName("侧键诊断")
        .description("验证侧键、灵动岛和录音是否能启动")
    }
}

private struct MindropQuickVoiceLockScreenView: View {
    let context: ActivityViewContext<MindropQuickVoiceActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    MindropWidgetIcon(size: 22)
                    Text("念落笔记")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                MindropWaveformView(seed: context.state.waveformSeed, isActive: context.state.phase == .recording)
                    .frame(width: 112, height: 28)

                Text(lockScreenText(for: context.state))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(context.state.phase == .completed ? Color.mindropAccent : .primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 8)
            MindropLiveActivityAction(context: context, isCompact: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func lockScreenText(for state: MindropQuickVoiceActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .recording:
            state.transcript.isEmpty ? "说点什么，小落正在听。" : state.transcript
        case .processing:
            state.transcript.isEmpty ? "小落正在处理。" : state.transcript
        case .completed:
            state.response.isEmpty ? "小落：已完成" : state.response
        case .failed, .permissionDenied:
            state.response
        }
    }
}

private struct MindropExpandedVoiceContent: View {
    let state: MindropQuickVoiceActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.transcript.isEmpty ? "说点什么，小落会实时记下来。" : state.transcript)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if state.phase == .completed {
                Text(state.response)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mindropAccent)
                    .lineLimit(2)
            } else if state.phase == .processing {
                Text("小落正在整理")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if state.phase == .failed || state.phase == .permissionDenied {
                Text(state.response)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                MindropWaveformView(seed: state.waveformSeed, isActive: true)
                    .frame(width: 120, height: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

private struct MindropLiveActivityAction: View {
    let context: ActivityViewContext<MindropQuickVoiceActivityAttributes>
    var isCompact: Bool

    var body: some View {
        switch context.state.phase {
        case .recording:
            Button(intent: MindropSendQuickVoiceIntent(sessionID: context.attributes.sessionID)) {
                Image(systemName: "arrow.up")
                    .font(.system(size: isCompact ? 11 : 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: isCompact ? 22 : 34, height: isCompact ? 22 : 34)
                    .background(Circle().fill(Color.mindropAccent))
            }
            .buttonStyle(.plain)
        case .processing:
            ProgressView()
                .controlSize(.mini)
                .tint(.mindropAccent)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: isCompact ? 12 : 16, weight: .bold))
                .foregroundStyle(Color.mindropAccent)
        case .failed, .permissionDenied:
            Image(systemName: "exclamationmark")
                .font(.system(size: isCompact ? 12 : 16, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MindropCompactStatusView: View {
    let state: MindropQuickVoiceActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            MindropWaveformView(seed: state.waveformSeed, isActive: true)
                .frame(width: 28, height: 18)
        case .processing:
            ProgressView()
                .controlSize(.mini)
                .tint(.mindropAccent)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.mindropAccent)
        case .failed, .permissionDenied:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MindropWaveformView: View {
    var seed: Int
    var isActive: Bool

    private let barCount = 9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(isActive ? Color.mindropAccent : Color.secondary.opacity(0.45))
                    .frame(width: 3, height: height(for: index))
                    .opacity(isActive ? 0.95 : 0.5)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func height(for index: Int) -> CGFloat {
        let values: [CGFloat] = [8, 14, 20, 26, 18, 12, 16, 23, 10]
        guard isActive else { return 10 }
        return values[(index + seed) % values.count]
    }
}

private struct MindropWidgetIcon: View {
    var size: CGFloat

    var body: some View {
        Image("BrandIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private extension Color {
    static let mindropAccent = Color(red: 0.22, green: 0.48, blue: 0.86)
    static let mindropActivityBackground = Color(red: 0.98, green: 0.985, blue: 0.99)
}
