import SwiftUI
import UIKit

private enum InputComposerPresentation: Equatable {
    case idle
    case text
    case voice
}

struct InputView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var draftText: String
    let speechState: SpeechState
    let transcript: String
    let submit: () -> Void
    let startVoiceInput: () -> Void
    let finishVoiceInput: () -> Void
    let cancelVoiceInput: () -> Void
    @Binding var isVoiceComposerActive: Bool
    @State private var isInputChromeHidden = false
    @State private var isTrackingMessageScroll = false
    @State private var revealInputChromeWorkItem: DispatchWorkItem?
    @State private var inputComposerPresentation: InputComposerPresentation = .idle
    @State private var textInputCloseRequestID = 0
    private let bottomAnchorID = "message-bottom-anchor"

    private var inputComposerBottomPadding: CGFloat {
        switch inputComposerPresentation {
        case .idle:
            return 86
        case .text:
            return 6
        case .voice:
            return -6
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.appCanvas
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("对话记录")
                                .font(.system(size: 29, weight: .semibold))
                                .foregroundStyle(Color.mindInk)

                            Text("内容由AI生成，请注意甄别。")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.mindInk.opacity(0.40))
                        }

                        Spacer(minLength: 8)

                        if store.isAIThinkingModeToggleAvailable {
                            AIThinkingModeMenu(mode: $store.aiThinkingMode)
                                .padding(.top, 2)
                        }
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
                                        ChatBubble(
                                            message: message,
                                            isReadOnlySample: store.isChatSampleMessage(message)
                                        )
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
                        .contentShape(Rectangle())
                        .coordinateSpace(name: "messageScroll")
                        .simultaneousGesture(messageScrollGesture)
                        .simultaneousGesture(chatAreaTapGesture)
                        .onPreferenceChange(MessageScrollOffsetKey.self) { _ in
                            guard isTrackingMessageScroll else { return }
                            scheduleInputChromeReveal()
                        }
                        .onAppear {
                            scrollToBottom(scrollProxy, animated: false)
                        }
                        .onChange(of: store.chatMessagesForDisplay.count) { _, _ in
                            scrollToBottom(scrollProxy)
                        }
                        .onChange(of: store.chatMessagesForDisplay.last?.text) { _, _ in
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
                    presentation: $inputComposerPresentation,
                    closeTextInputRequestID: textInputCloseRequestID,
                    availableWidth: proxy.size.width,
                    speechState: speechState,
                    transcript: transcript,
                    submit: submit,
                    startVoiceInput: startVoiceInput,
                    finishVoiceInput: finishVoiceInput,
                    cancelVoiceInput: cancelVoiceInput
                )
                .offset(x: isInputChromeHidden ? proxy.size.width : 0)
                .opacity(isInputChromeHidden ? 0 : 1)
                .allowsHitTesting(!isInputChromeHidden)
                .padding(.bottom, inputComposerBottomPadding)
                .offset(y: inputComposerPresentation == .voice ? 64 : 0)
                .animation(.spring(response: 0.38, dampingFraction: 0.84), value: isInputChromeHidden)
                .animation(.spring(response: 0.36, dampingFraction: 0.82), value: inputComposerPresentation)
                .ignoresSafeArea(.container, edges: inputComposerPresentation == .voice ? .bottom : [])
            }
            .onAppear {
                updateVoiceComposerActive(for: inputComposerPresentation)
                if store.selectedTab == .input {
                    playInputChromeEntrance(after: 0.12)
                }
            }
            .onChange(of: store.selectedTab) { _, tab in
                guard tab == .input else {
                    isVoiceComposerActive = false
                    cancelPendingInputChromeReveal()
                    return
                }
                playInputChromeEntrance()
                updateVoiceComposerActive(for: inputComposerPresentation)
            }
            .onChange(of: inputComposerPresentation) { _, presentation in
                updateVoiceComposerActive(for: presentation)
            }
            .onDisappear {
                isVoiceComposerActive = false
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
                if inputComposerPresentation == .text {
                    requestTextInputClose()
                    return
                }
                isTrackingMessageScroll = true
                hideInputChromeForScroll()
            }
            .onEnded { _ in
                scheduleInputChromeReveal()
            }
    }

    private var chatAreaTapGesture: some Gesture {
        TapGesture()
            .onEnded {
                requestTextInputClose()
            }
    }

    private var messageDaySections: [ChatDaySection] {
        let calendar = Calendar.current
        let messagesByDay = Dictionary(grouping: store.chatMessagesForDisplay) { message in
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
        if inputComposerPresentation == .text {
            requestTextInputClose()
            return
        }
        guard inputComposerPresentation == .idle else { return }
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

    private func requestTextInputClose() {
        guard inputComposerPresentation == .text else { return }
        textInputCloseRequestID += 1
    }

    private func updateVoiceComposerActive(for presentation: InputComposerPresentation) {
        isVoiceComposerActive = presentation == .voice && store.selectedTab == .input
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

private struct AIThinkingModeMenu: View {
    @Binding var mode: AIThinkingMode
    @State private var isClickRingVisible = false
    @State private var clickRingProgress: CGFloat = 0
    @State private var clickRingWorkItem: DispatchWorkItem?

    var body: some View {
        Button {
            HapticFeedback.selectionChanged()
            playClickRing()
            withAnimation(.easeInOut(duration: 0.16)) {
                mode = mode == .fast ? .thinking : .fast
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImageName)
                    .font(.system(size: 11, weight: .heavy))
                Text(mode.title)
                    .font(.system(size: 13, weight: .heavy))
            }
            .foregroundStyle(mode == .thinking ? Color.mindAccent : Color.mindInk.opacity(0.68))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background {
                Capsule()
                    .fill(Color.cardSurface.opacity(0.88))
                    .shadow(color: .black.opacity(0.025), radius: 8, y: 4)
            }
            .overlay {
                ZStack {
                    Capsule()
                        .stroke(
                            mode == .thinking ? Color.mindAccent.opacity(0.22) : Color.separatorLine,
                            lineWidth: 1
                        )

                    if isClickRingVisible {
                        ModeSwitchClickRing(progress: clickRingProgress)
                            .transition(.opacity)
                    }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onDisappear {
            clickRingWorkItem?.cancel()
        }
        .accessibilityLabel("AI回复模式")
        .accessibilityValue(mode.title)
        .accessibilityHint("点击切换到\(mode == .fast ? AIThinkingMode.thinking.title : AIThinkingMode.fast.title)")
    }

    private func playClickRing() {
        clickRingWorkItem?.cancel()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isClickRingVisible = true
            clickRingProgress = 0
        }

        DispatchQueue.main.async {
            withAnimation(.linear(duration: 0.5)) {
                clickRingProgress = 1
            }
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.12)) {
                isClickRingVisible = false
            }
        }
        clickRingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}

private struct ModeSwitchClickRing: View {
    let progress: CGFloat

    var body: some View {
        ZStack {
            Capsule()
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.mindAccent.opacity(0.95),
                            Color(red: 0.36, green: 0.66, blue: 1.00).opacity(0.92),
                            Color(red: 0.96, green: 0.70, blue: 0.24).opacity(0.88),
                            Color(red: 0.92, green: 0.36, blue: 0.58).opacity(0.88),
                            Color.mindAccent.opacity(0.95)
                        ],
                        center: .center
                        ),
                        lineWidth: 1.2
                    )
                    .opacity(0.24)

                CapsuleOrbitSegment(progress: progress, length: 0.32)
                    .stroke(
                        AngularGradient(
                        colors: [
                            Color(red: 0.40, green: 0.72, blue: 1.00),
                            Color(red: 1.00, green: 0.78, blue: 0.28),
                            Color(red: 0.92, green: 0.32, blue: 0.62),
                            Color.mindAccent,
                            Color(red: 0.40, green: 0.72, blue: 1.00)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: Color.mindAccent.opacity(0.28), radius: 4)
            }
        .padding(-2)
        .allowsHitTesting(false)
    }
}

private struct CapsuleOrbitSegment: Shape {
    var progress: CGFloat
    let length: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let lineInset: CGFloat = 1.5
        let pathRect = rect.insetBy(dx: lineInset, dy: lineInset)
        let basePath = Path(
            roundedRect: pathRect,
            cornerRadius: pathRect.height / 2,
            style: .continuous
        )
        let start = progress - floor(progress)
        let clampedLength = min(max(length, 0.02), 0.96)
        let end = start + clampedLength

        var path = Path()
        if end <= 1 {
            path.addPath(basePath.trimmedPath(from: start, to: end))
        } else {
            path.addPath(basePath.trimmedPath(from: start, to: 1))
            path.addPath(basePath.trimmedPath(from: 0, to: end - 1))
        }
        return path
    }
}

private struct ChatBubble: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage
    var isReadOnlySample = false

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

                if message.category == .qa && store.streamingAssistantMessageID != message.id && !isReadOnlySample {
                    Button("保存至灵感沉淀") {
                        HapticFeedback.lightImpact()
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

                if !isReadOnlySample {
                    Button(role: .destructive) {
                        store.deleteChatMessage(message)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
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
    @Binding var presentation: InputComposerPresentation
    let closeTextInputRequestID: Int
    let availableWidth: CGFloat
    let speechState: SpeechState
    let transcript: String
    let submit: () -> Void
    let startVoiceInput: () -> Void
    let finishVoiceInput: () -> Void
    let cancelVoiceInput: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isTextInputVisible = false
    @State private var isTriggerPressed = false
    @State private var isVoicePressed = false
    @State private var isCancelingVoice = false
    @State private var didStartVoice = false
    @State private var holdWorkItem: DispatchWorkItem?
    @State private var voiceStartWorkItem: DispatchWorkItem?

    private let idleWidth: CGFloat = 148
    private let sideInset: CGFloat = 22
    private let voiceSideInset: CGFloat = 18
    private let idleTrailingInset: CGFloat = 14

    private var panelWidth: CGFloat {
        max(280, availableWidth - sideInset * 2)
    }

    private var voicePanelWidth: CGFloat {
        max(280, availableWidth - voiceSideInset * 2)
    }

    private var voiceMode: Bool {
        isVoicePressed || speechState.isRecording
    }

    private var currentPresentation: InputComposerPresentation {
        if voiceMode { return .voice }
        if isTextInputVisible { return .text }
        return .idle
    }

    private var isExpanded: Bool {
        isTextInputVisible || voiceMode
    }

    private let textPanelHeight: CGFloat = 112

    private var voicePanelHeight: CGFloat {
        min(320, max(276, availableWidth * 0.78))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if !isExpanded {
                idleTrigger
                    .padding(.trailing, idleTrailingInset)
                    .transition(.scale(scale: 0.18, anchor: .bottomTrailing).combined(with: .opacity))
            }

            if isTextInputVisible && !voiceMode {
                textInputPanel
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.scale(scale: 0.18, anchor: .bottomTrailing).combined(with: .opacity))
            }

            voiceInputPanel
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(voiceMode ? 1 : 0)
                .offset(y: voiceMode ? 0 : voicePanelHeight + 44)
                .allowsHitTesting(false)
                .accessibilityHidden(!voiceMode)

            VoiceHoldControl(
                onBegan: beginTriggerPress,
                onMoved: updateVoiceCancelState,
                onEnded: endTriggerPress
            )
            .frame(width: voiceMode ? voicePanelWidth : 70, height: voiceMode ? voicePanelHeight : 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(width: availableWidth, height: voiceMode ? voicePanelHeight : (isTextInputVisible ? textPanelHeight : 92), alignment: .bottomTrailing)
        .animation(.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.08), value: isTextInputVisible)
        .animation(.easeOut(duration: 0.24), value: voiceMode)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isCancelingVoice)
        .onAppear {
            presentation = currentPresentation
        }
        .onChange(of: currentPresentation) { _, value in
            presentation = value
        }
        .onChange(of: closeTextInputRequestID) { _, _ in
            closeTextInput()
        }
        .onChange(of: isFocused) { _, focused in
            guard !isTriggerPressed, !focused, draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("你只管说，剩下的交给我", text: $draftText, axis: .vertical)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(commitText)
                .onChange(of: draftText) { _, value in
                    submitTextIfNeededAfterReturn(in: value)
                }
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.mindInk.opacity(0.86))
                .lineLimit(2...3)
                .textFieldStyle(.plain)
                .frame(minHeight: 66, alignment: .topLeading)
                .padding(.vertical, 8)

            Button(action: commitText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 31, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.mindInk.opacity(0.80))
            }
            .frame(width: 40, height: 40)
            .buttonStyle(.plain)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: panelWidth, height: textPanelHeight)
        .background {
            InputGlassBackground(cornerRadius: 32)
        }
    }

    private var voiceInputPanel: some View {
        VStack(spacing: 0) {
            Text(isCancelingVoice ? "松手取消发送" : "松开即可发送")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isCancelingVoice ? Color.red.opacity(0.72) : Color.mindInk.opacity(0.42))
                .padding(.top, 18)

            Spacer(minLength: 14)

            VStack(spacing: 14) {
                Text(voiceText)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.mindInk.opacity(0.74))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .center)

                InputWaveformView()
                    .frame(height: 34)
            }

            Spacer(minLength: 14)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill((isCancelingVoice ? Color.red : Color.mindInk).opacity(isCancelingVoice ? 0.10 : 0.05))

                TrashCancelIcon(isOpen: isCancelingVoice)
                    .frame(width: 54, height: 54)
                    .foregroundStyle(isCancelingVoice ? Color.red.opacity(0.74) : Color.mindInk.opacity(0.42))
            }
            .frame(maxWidth: .infinity)
            .frame(height: voicePanelHeight / 3)
        }
        .frame(width: voicePanelWidth, height: voicePanelHeight)
        .background {
            InputGlassBackground(cornerRadius: 36)
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

    private func submitTextIfNeededAfterReturn(in value: String) {
        guard value.contains(where: \.isNewline) else { return }
        let sanitized = value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        draftText = sanitized
        guard !sanitized.isEmpty else { return }
        commitText()
    }

    private func closeTextInput() {
        guard isTextInputVisible, !voiceMode else { return }
        isFocused = false
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            isTextInputVisible = false
        }
    }

    private func beginTriggerPress() {
        guard !voiceMode else { return }
        HapticFeedback.lightImpact()
        isTriggerPressed = true
        if isTextInputVisible {
            isFocused = false
        }
        let workItem = DispatchWorkItem {
            guard isTriggerPressed else { return }
            beginVoiceHold()
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func updateVoiceCancelState(_ location: CGPoint?) {
        guard voiceMode, let location else { return }
        let shouldCancel = location.y > voicePanelHeight * (2.0 / 3.0)
        guard shouldCancel != isCancelingVoice else { return }
        isCancelingVoice = shouldCancel
        HapticFeedback.selectionChanged()
    }

    private func endTriggerPress(_ location: CGPoint?) {
        updateVoiceCancelState(location)
        let wasTextInputVisible = isTextInputVisible
        let shouldOpenTextInput = !didStartVoice
        holdWorkItem?.cancel()
        holdWorkItem = nil
        isTriggerPressed = false

        if didStartVoice {
            endVoiceHold()
        } else if shouldOpenTextInput && wasTextInputVisible {
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isFocused = true
            } else {
                commitText()
            }
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
        isCancelingVoice = false
        isFocused = false
        isTextInputVisible = false
        withAnimation(.easeOut(duration: 0.24)) {
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
        let shouldCancel = isCancelingVoice
        didStartVoice = false
        isCancelingVoice = false
        voiceStartWorkItem?.cancel()
        voiceStartWorkItem = nil
        withAnimation(.easeOut(duration: 0.20)) {
            isVoicePressed = false
        }
        if shouldCancel {
            cancelVoiceInput()
        } else {
            finishVoiceInput()
        }
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

private struct TrashCancelIcon: View {
    let isOpen: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(lineWidth: 2.4)
                .frame(width: 28, height: 31)
                .offset(y: 7)

            ZStack {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.foreground)
                    .frame(width: 12, height: 4)
                    .offset(y: -3)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.foreground)
                    .frame(width: 34, height: 4)
                    .offset(y: 3)
            }
            .frame(width: 34, height: 12)
            .rotationEffect(.degrees(isOpen ? -24 : 0), anchor: .leading)
            .offset(y: isOpen ? -18 : -15)

            HStack(spacing: 5) {
                Capsule().fill(.foreground).frame(width: 2.2, height: 17)
                Capsule().fill(.foreground).frame(width: 2.2, height: 17)
            }
            .opacity(0.70)
            .offset(y: 9)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: isOpen)
    }
}

private struct VoiceHoldControl: UIViewRepresentable {
    var onBegan: () -> Void
    var onMoved: (CGPoint?) -> Void
    var onEnded: (CGPoint?) -> Void

    func makeUIView(context: Context) -> TrackingControl {
        let control = TrackingControl()
        control.backgroundColor = .clear
        control.isMultipleTouchEnabled = false
        return control
    }

    func updateUIView(_ uiView: TrackingControl, context: Context) {
        uiView.onBegan = onBegan
        uiView.onMoved = onMoved
        uiView.onEnded = onEnded
    }

    final class TrackingControl: UIControl {
        var onBegan: (() -> Void)?
        var onMoved: ((CGPoint?) -> Void)?
        var onEnded: ((CGPoint?) -> Void)?

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            onBegan?()
            onMoved?(touch.location(in: self))
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            onMoved?(touch.location(in: self))
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            onEnded?(touch?.location(in: self))
        }

        override func cancelTracking(with event: UIEvent?) {
            onEnded?(nil)
        }
    }
}
