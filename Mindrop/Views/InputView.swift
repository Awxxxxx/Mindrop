import SwiftUI
import UIKit

struct InputView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var draftText: String
    let speechState: SpeechState
    let transcript: String
    let submit: () -> Void
    let startVoiceInput: () -> Void
    let finishVoiceInput: () -> Void
    @State private var isInputChromeHidden = false
    @State private var isTrackingMessageScroll = false
    @State private var revealInputChromeWorkItem: DispatchWorkItem?
    private let bottomAnchorID = "message-bottom-anchor"

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.appCanvas
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("对话记录")
                            .font(.system(size: 29, weight: .semibold))
                            .foregroundStyle(Color.mindInk)

                        Text("内容由AI生成，请注意甄别。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.mindInk.opacity(0.40))
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 58)
                        .padding(.bottom, 14)

                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(spacing: 13) {
                                if store.hasTrimmedChatHistory {
                                    Text("仅展示最近100条消息")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color.mindInk.opacity(0.36))
                                        .padding(.top, 2)
                                }

                                ForEach(messageDaySections) { section in
                                    Text(section.title)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.mindInk.opacity(0.44))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.controlSurface, in: Capsule())
                                        .padding(.top, 4)

                                    ForEach(section.messages) { message in
                                        ChatBubble(message: message)
                                            .id(message.id)
                                    }
                                }

                                if store.isAIThinking {
                                    ThinkingBubble()
                                        .id("ai-thinking-bubble")
                                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id(bottomAnchorID)
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                            .background(scrollOffsetReader)
                        }
                        .coordinateSpace(name: "messageScroll")
                        .simultaneousGesture(messageScrollGesture)
                        .onPreferenceChange(MessageScrollOffsetKey.self) { _ in
                            guard isTrackingMessageScroll else { return }
                            scheduleInputChromeReveal()
                        }
                        .onAppear {
                            scrollToBottom(scrollProxy, animated: false)
                        }
                        .onChange(of: store.messages.count) { _, _ in
                            scrollToBottom(scrollProxy)
                        }
                        .onChange(of: store.messages.last?.text) { _, _ in
                            scrollToBottom(scrollProxy)
                        }
                        .onChange(of: store.isAIThinking) { _, _ in
                            scrollToBottom(scrollProxy)
                        }
                        .onChange(of: store.selectedTab) { _, tab in
                            guard tab == .input else { return }
                            scrollToBottom(scrollProxy, animated: false)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .bottomTrailing) {
                FloatingInputTrigger(
                    draftText: $draftText,
                    availableWidth: proxy.size.width,
                    speechState: speechState,
                    transcript: transcript,
                    submit: submit,
                    startVoiceInput: startVoiceInput,
                    finishVoiceInput: finishVoiceInput
                )
                .offset(x: isInputChromeHidden ? proxy.size.width : 0)
                .opacity(isInputChromeHidden ? 0 : 1)
                .allowsHitTesting(!isInputChromeHidden)
                .padding(.bottom, 86)
                .animation(.spring(response: 0.38, dampingFraction: 0.84), value: isInputChromeHidden)
            }
            .onAppear {
                if store.selectedTab == .input {
                    playInputChromeEntrance(after: 0.12)
                }
            }
            .onChange(of: store.selectedTab) { _, tab in
                guard tab == .input else {
                    cancelPendingInputChromeReveal()
                    return
                }
                playInputChromeEntrance()
            }
        }
    }

    private var scrollOffsetReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MessageScrollOffsetKey.self,
                value: proxy.frame(in: .named("messageScroll")).minY
            )
        }
        .frame(height: 0)
    }

    private var messageScrollGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                guard store.selectedTab == .input else { return }
                isTrackingMessageScroll = true
                hideInputChromeForScroll()
            }
            .onEnded { _ in
                scheduleInputChromeReveal()
            }
    }

    private var messageDaySections: [ChatDaySection] {
        let calendar = Calendar.current
        let messagesByDay = Dictionary(grouping: store.messages) { message in
            calendar.startOfDay(for: message.createdAt)
        }
        return messagesByDay.keys.sorted().map { day in
            ChatDaySection(
                day: day,
                title: chatDayTitle(for: day),
                messages: messagesByDay[day, default: []].sorted { $0.createdAt < $1.createdAt }
            )
        }
    }

    private func chatDayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        let components = calendar.dateComponents([.month, .day], from: date)
        if let month = components.month, let day = components.day {
            return "\(month)月\(day)日"
        }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }

    private func hideInputChromeForScroll() {
        cancelPendingInputChromeReveal()
        guard !isInputChromeHidden else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
            isInputChromeHidden = true
        }
    }

    private func scheduleInputChromeReveal() {
        guard store.selectedTab == .input else { return }
        cancelPendingInputChromeReveal()
        let workItem = DispatchWorkItem {
            isTrackingMessageScroll = false
            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                isInputChromeHidden = false
            }
        }
        revealInputChromeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: workItem)
    }

    private func playInputChromeEntrance(after delay: TimeInterval = 0.04) {
        cancelPendingInputChromeReveal()
        isTrackingMessageScroll = false

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isInputChromeHidden = true
        }

        let workItem = DispatchWorkItem {
            guard store.selectedTab == .input else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                isInputChromeHidden = false
            }
        }
        revealInputChromeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingInputChromeReveal() {
        revealInputChromeWorkItem?.cancel()
        revealInputChromeWorkItem = nil
    }

    private func scrollToBottom(_ scrollProxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

private struct ChatDaySection: Identifiable {
    let day: Date
    let title: String
    let messages: [ChatMessage]

    var id: Date { day }
}

private struct MessageScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatBubble: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 56) }

            VStack(alignment: .leading, spacing: 10) {
                if let category = message.category {
                    Text(category.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(labelColor(for: category))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(labelColor(for: category).opacity(0.11), in: Capsule())
                }

                Text(message.text)
                    .font(.callout)
                    .lineSpacing(2)

                if message.category == .qa && store.streamingAssistantMessageID != message.id {
                    Button("保存至灵感沉淀") {
                        store.saveConversationToIdea(message: message)
                    }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.mindAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.mindAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .foregroundStyle(message.role == .user ? .white : Color.mindInk)
            .padding(14)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                    store.presentToast("已复制")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    store.deleteChatMessage(message)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var background: some View {
        if message.role == .user {
            Color.mindAccent
        } else {
            Color.cardSurface.opacity(0.96)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.separatorLine, lineWidth: 1))
        }
    }

    private func labelColor(for category: ThoughtCategory) -> Color {
        switch category {
        case .todo: Color(red: 0.66, green: 0.47, blue: 0.14)
        case .bill: Color(red: 0.68, green: 0.36, blue: 0.45)
        case .qa: Color(red: 0.30, green: 0.53, blue: 0.50)
        case .idea: Color.mindAccent
        case .recycleBin: .gray
        }
    }
}

private struct ThinkingBubble: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("小落正在思考")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.mindInk.opacity(0.46))

                TimelineView(.animation) { timeline in
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { index in
                            ThinkingDot(time: timeline.date.timeIntervalSinceReferenceDate, index: index)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .frame(width: 58, height: 18, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                Color.cardSurface.opacity(0.96)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.separatorLine, lineWidth: 1))
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Spacer(minLength: 48)
        }
    }
}

private struct ThinkingDot: View {
    let time: TimeInterval
    let index: Int

    private var progress: Double {
        let phase = (time * 2.4) - Double(index) * 0.22
        return (sin(phase * .pi * 2) + 1) / 2
    }

    var body: some View {
        Circle()
            .fill(Color.mindInk.opacity(0.42 + progress * 0.26))
            .frame(width: 7, height: 7)
            .scaleEffect(0.82 + progress * 0.24)
            .offset(y: -progress * 4)
    }
}

private struct FloatingInputTrigger: View {
    @Binding var draftText: String
    let availableWidth: CGFloat
    let speechState: SpeechState
    let transcript: String
    let submit: () -> Void
    let startVoiceInput: () -> Void
    let finishVoiceInput: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isTextInputVisible = false
    @State private var isTriggerPressed = false
    @State private var isVoicePressed = false
    @State private var didStartVoice = false
    @State private var holdWorkItem: DispatchWorkItem?
    @State private var voiceStartWorkItem: DispatchWorkItem?

    private let idleWidth: CGFloat = 148
    private let sideInset: CGFloat = 22
    private let idleTrailingInset: CGFloat = 14

    private var panelWidth: CGFloat {
        max(280, availableWidth - sideInset * 2)
    }

    private var voiceMode: Bool {
        isVoicePressed || speechState.isRecording
    }

    private var isExpanded: Bool {
        isTextInputVisible || voiceMode
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if !isExpanded {
                idleTrigger
                    .padding(.trailing, idleTrailingInset)
                    .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
            }

            if isTextInputVisible && !voiceMode {
                textInputPanel
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.scale(scale: 0.95, anchor: .bottomTrailing).combined(with: .opacity))
            }

            if voiceMode {
                voiceInputPanel
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
            }

            VoiceHoldControl(
                onBegan: beginTriggerPress,
                onEnded: endTriggerPress
            )
            .frame(width: 70, height: 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(!isTextInputVisible || voiceMode)
        }
        .frame(width: isExpanded ? availableWidth : idleWidth + idleTrailingInset, height: voiceMode ? 150 : (isTextInputVisible ? 74 : 92), alignment: .bottomTrailing)
        .animation(.spring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.08), value: isExpanded)
        .onChange(of: isFocused) { _, focused in
            guard !focused, draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                isTextInputVisible = false
            }
        }
    }

    private var idleTrigger: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("点击输入，按住说话")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mindInk.opacity(0.42))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.cardSurface.opacity(0.68), in: Capsule())

            ZStack {
                InputGlassBackground(cornerRadius: 31)
                    .frame(width: 62, height: 62)

                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.mindInk.opacity(0.80))
                    .scaleEffect(isTriggerPressed ? 0.88 : 1)
            }
            .frame(width: 62, height: 62)
        }
        .frame(width: idleWidth, alignment: .trailing)
    }

    private var textInputPanel: some View {
        HStack(spacing: 10) {
            TextField("你只管说，剩下的交给我", text: $draftText)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(commitText)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.mindInk.opacity(0.86))
                .lineLimit(1)
                .textFieldStyle(.plain)

            Button(action: commitText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.mindInk.opacity(0.80))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 12)
        .frame(width: panelWidth, height: 62)
        .background {
            InputGlassBackground(cornerRadius: 31)
        }
    }

    private var voiceInputPanel: some View {
        VStack(spacing: 16) {
            Text(voiceText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.mindInk.opacity(0.74))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)

            InputWaveformView()
                .frame(height: 34)
        }
        .padding(.horizontal, 22)
        .frame(width: panelWidth, height: 132)
        .background {
            InputGlassBackground(cornerRadius: 32)
        }
    }

    private var voiceText: String {
        let recognized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recognized.isEmpty { return recognized }
        let draft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? "按住说话中..." : draft
    }

    private func commitText() {
        isFocused = false
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            isTextInputVisible = false
        }
        submit()
    }

    private func beginTriggerPress() {
        guard !isExpanded else { return }
        isTriggerPressed = true
        let workItem = DispatchWorkItem {
            guard isTriggerPressed else { return }
            beginVoiceHold()
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func endTriggerPress() {
        let shouldOpenTextInput = !didStartVoice
        holdWorkItem?.cancel()
        holdWorkItem = nil
        isTriggerPressed = false

        if didStartVoice {
            endVoiceHold()
        } else if shouldOpenTextInput {
            showTextInput()
        }
    }

    private func showTextInput() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            isTextInputVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            guard isTextInputVisible, !voiceMode else { return }
            isFocused = true
        }
    }

    private func beginVoiceHold() {
        guard !didStartVoice else { return }
        didStartVoice = true
        isFocused = false
        isTextInputVisible = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.74)) {
            isVoicePressed = true
        }
        let workItem = DispatchWorkItem {
            startVoiceInput()
            voiceStartWorkItem = nil
        }
        voiceStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
    }

    private func endVoiceHold() {
        guard didStartVoice else { return }
        didStartVoice = false
        voiceStartWorkItem?.cancel()
        voiceStartWorkItem = nil
        withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
            isVoicePressed = false
        }
        finishVoiceInput()
    }
}

private struct InputGlassBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: shape)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
        }
    }
}

private struct InputWaveformView: View {
    private let bars = Array(0..<16)

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(bars, id: \.self) { index in
                    let phase = time * 5.8 + Double(index) * 0.52
                    let normalized = (sin(phase) + 1) / 2
                    Capsule()
                        .fill(Color.mindInk.opacity(0.54))
                        .frame(width: 3, height: 8 + normalized * 24)
                }
            }
        }
    }
}

private struct VoiceHoldControl: UIViewRepresentable {
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> TrackingControl {
        let control = TrackingControl()
        control.backgroundColor = .clear
        control.isMultipleTouchEnabled = false
        return control
    }

    func updateUIView(_ uiView: TrackingControl, context: Context) {
        uiView.onBegan = onBegan
        uiView.onEnded = onEnded
    }

    final class TrackingControl: UIControl {
        var onBegan: (() -> Void)?
        var onEnded: (() -> Void)?

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            onBegan?()
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            onEnded?()
        }

        override func cancelTracking(with event: UIEvent?) {
            onEnded?()
        }
    }
}
