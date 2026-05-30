import SwiftUI
import UIKit

enum HapticFeedback {
    static func lightImpact() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    static func selectionChanged() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        VStack {
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            Spacer()
        }
        .padding(.top, 62)
    }
}

struct BrandMark: View {
    var size: CGFloat = 112

    var body: some View {
        Image("BrandIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 16, y: 8)
    }
}

struct IconCircleButton: View {
    let systemName: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.mindInk)
                .frame(width: 44, height: 44)
                .background(Color.cardSurface.opacity(0.94), in: Circle())
                .overlay(Circle().stroke(Color.separatorLine, lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

struct NoteCardView: View {
    let note: ThoughtNote

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if note.isPinned {
                    Text("↑置顶")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.mindInk.opacity(0.58))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(note.category.noteColor.opacity(0.18), in: Capsule())
                }
                Text(note.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.mindInk)
                    .lineLimit(1)
                Spacer()
                if let billAmountText {
                    Text(billAmountText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.mindInk.opacity(0.62))
                        .lineLimit(1)
                } else {
                    Text(createdAtText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.mindInk.opacity(0.64))
                        .lineLimit(1)
                }
            }

            Text(note.content)
                .font(.footnote)
                .foregroundStyle(Color.mindInk.opacity(0.58))
                .lineLimit(3)

            if note.category == .todo, let reminderAt = note.reminderAt {
                Text("提醒时间：\(reminderAtText(reminderAt))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.mindInk.opacity(0.56))
                    .padding(.top, 2)
            }
        }
        .padding(15)
        .padding(.leading, 3)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cardSurface.opacity(0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.separatorLine, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(note.category.noteColor)
                .frame(width: 3)
                .padding(.vertical, 15)
        }
        .shadow(color: .black.opacity(0.035), radius: 10, y: 5)
    }

    private var createdAtText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(note.createdAt) {
            return note.createdAt.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(note.createdAt) {
            return "昨天"
        }
        let components = calendar.dateComponents([.month, .day], from: note.createdAt)
        if let month = components.month, let day = components.day {
            return "\(month)月\(day)日"
        }
        return note.createdAt.formatted(.dateTime.month(.defaultDigits).day())
    }

    private var billAmountText: String? {
        guard note.category == .bill, let amount = note.expenseAmount else { return nil }
        return "¥\(NSDecimalNumber(decimal: amount).stringValue)"
    }

    private func reminderAtText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 " + date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 " + date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInTomorrow(date) {
            return "明天 " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
    }
}

struct PaperTexture: View {
    var body: some View {
        Canvas { context, size in
            for index in stride(from: 0, through: size.height, by: 7) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: index))
                path.addLine(to: CGPoint(x: size.width, y: index))
                context.stroke(path, with: .color(.brown.opacity(0.10)), lineWidth: 0.5)
            }
        }
    }
}

struct LiquidTabBar: View {
    @Binding var selectedTab: AppTab
    @Binding var draftText: String
    var isRecording: Bool
    var submit: () -> Void
    var startVoiceInput: () -> Void
    var finishVoiceInput: () -> Void
    @FocusState private var isComposerFocused: Bool
    @State private var isComposerPressed = false
    @State private var isVoiceHoldActive = false
    @State private var isTextEditingMode = false
    @State private var longPressWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            dockBackdrop

            tabContent

            composerTouchLayer
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .onChange(of: isComposerFocused) { _, isFocused in
            guard !isFocused else { return }
            withAnimation(composerMorphAnimation) {
                isTextEditingMode = false
            }
        }
    }

    private var tabContent: some View {
        HStack(spacing: isExpanded ? 0 : 10) {
            if !isExpanded {
                orb(tab: .history, icon: "clock.arrow.circlepath")
                    .transition(.opacity.combined(with: .scale(scale: 0.84)))
            }
            composer
            if !isExpanded {
                orb(tab: .profile, icon: "person.crop.circle")
                    .transition(.opacity.combined(with: .scale(scale: 0.84)))
            }
        }
        .frame(height: tabHeight)
        .animation(composerMorphAnimation, value: isExpanded)
    }

    private var voiceMode: Bool {
        isVoiceHoldActive || isRecording
    }

    private var textMode: Bool {
        isTextEditingMode && !voiceMode
    }

    private var isExpanded: Bool {
        voiceMode || textMode
    }

    private var composerHeight: CGFloat {
        if voiceMode { return 154 }
        if textMode { return 138 }
        return 54
    }

    private var tabHeight: CGFloat {
        isExpanded ? composerHeight + 10 : 60
    }

    private var composerCornerRadius: CGFloat {
        isExpanded ? 34 : 27
    }

    private var composerMorphAnimation: Animation {
        .spring(response: 0.36, dampingFraction: 0.76, blendDuration: 0.08)
    }

    private var composerTouchLayer: some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(width: 56)
                .allowsHitTesting(false)

            ComposerTouchOverlay(
                activeHitHeight: voiceMode ? composerHeight : 54,
                onBegan: beginComposerPressIfNeeded,
                onMoved: handleComposerPressMoved,
                onEnded: finishComposerPress
            )
            .frame(maxWidth: .infinity)
            .frame(height: max(118, composerHeight))

            Color.clear
                .frame(width: 56)
                .allowsHitTesting(false)
        }
        .frame(height: max(118, tabHeight))
        .allowsHitTesting(!textMode)
    }

    private var dockBackdrop: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.08),
                        .black.opacity(0.20)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 96)
            .blur(radius: 10)
            .allowsHitTesting(false)
    }

    private func orb(tab: AppTab, icon: String) -> some View {
        LiquidGlassControl(size: 56, shape: .circle, isActive: active(tab)) {
            selectedTab = tab
        } label: {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.mindInk.opacity(0.88))
                .shadow(color: Color.cardSurface.opacity(0.95), radius: 1.2)
                .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.4)
                .compositingGroup()
        }
    }

    @ViewBuilder
    private var composer: some View {
        ZStack {
            normalComposerControls
                .opacity(isExpanded ? 0 : 1)
                .blur(radius: isExpanded ? 5 : 0)
                .scaleEffect(isExpanded ? 0.94 : 1)

            textComposerControls
                .opacity(textMode ? 1 : 0)
                .blur(radius: textMode ? 0 : 8)
                .offset(y: textMode ? 0 : 18)
                .scaleEffect(textMode ? 1 : 0.96)
                .allowsHitTesting(textMode)

            voiceComposerControls
                .opacity(voiceMode ? 1 : 0)
                .blur(radius: voiceMode ? 0 : 8)
                .offset(y: voiceMode ? 0 : 20)
                .scaleEffect(voiceMode ? 1 : 0.95)
        }
        .frame(maxWidth: .infinity)
        .frame(height: composerHeight)
        .padding(.horizontal, isExpanded ? 24 : 7)
        .contentShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
        .modifier(
            LiquidGlassSurface(
                shape: isExpanded ? .roundedRectangle(cornerRadius: composerCornerRadius) : .capsule,
                isActive: active(.input) || isComposerPressed || isExpanded
            )
        )
        .scaleEffect(x: isExpanded ? 1.015 : (isComposerPressed ? 1.012 : 1), y: isExpanded ? 1.015 : (isComposerPressed ? 1.035 : 1))
        .animation(composerMorphAnimation, value: voiceMode)
        .animation(composerMorphAnimation, value: textMode)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.72), value: isComposerPressed)
    }

    private var normalComposerControls: some View {
        HStack(spacing: 8) {
            Text("Aa")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.mindInk.opacity(0.78))
                .frame(width: 30, height: 40)

            Text(draftText.isEmpty ? "发消息或按住说话" : draftText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(draftText.isEmpty ? Color.mindInk.opacity(0.56) : Color.mindInk.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "mic")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.mindInk.opacity(0.82))
                .frame(width: 30, height: 40)
                .opacity(0.86)
        }
    }

    private var textComposerControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("发消息或按住说话", text: $draftText, axis: .vertical)
                .focused($isComposerFocused)
                .submitLabel(.send)
                .onSubmit(commitTextInput)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color.mindInk.opacity(0.78))
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 20)
    }

    private var voiceComposerControls: some View {
        VStack(spacing: 18) {
            Text(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "正在聆听..." : draftText)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.mindInk.opacity(0.74))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)

            VoiceWaveformView()
                .frame(height: 38)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func beginComposerPressIfNeeded() {
        guard !isComposerPressed else { return }
        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.70)) {
            isComposerPressed = true
        }

        let workItem = DispatchWorkItem {
            guard isComposerPressed else { return }
            isComposerFocused = false
            withAnimation(composerMorphAnimation) {
                isTextEditingMode = false
                isVoiceHoldActive = true
            }
            startVoiceInput()
        }
        longPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func handleComposerPressMoved(_ translation: CGSize) {
        guard !isVoiceHoldActive else { return }
        if abs(translation.width) > 28 || abs(translation.height) > 28 {
            cancelPendingVoiceHold()
        }
    }

    private func finishComposerPress(_ translation: CGSize) {
        let shouldTap = abs(translation.width) < 18 && abs(translation.height) < 18
        let shouldFinishVoice = isVoiceHoldActive || isRecording
        cancelPendingVoiceHold()

        if shouldFinishVoice {
            endVoiceHold()
        } else if shouldTap {
            focusComposer()
        }

        withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.72)) {
            isComposerPressed = false
        }
    }

    private func cancelPendingVoiceHold() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }

    private func focusComposer() {
        withAnimation(composerMorphAnimation) {
            isVoiceHoldActive = false
            isTextEditingMode = true
        }
        DispatchQueue.main.async {
            isComposerFocused = true
        }
    }

    private func endVoiceHold() {
        withAnimation(composerMorphAnimation) {
            isVoiceHoldActive = false
        }
        finishVoiceInput()
    }

    private func commitTextInput() {
        isComposerFocused = false
        withAnimation(composerMorphAnimation) {
            isTextEditingMode = false
        }
        submit()
    }

    private func active(_ tab: AppTab) -> Bool {
        selectedTab == tab
    }
}

private struct ComposerTouchOverlay: UIViewRepresentable {
    var activeHitHeight: CGFloat
    var onBegan: () -> Void
    var onMoved: (CGSize) -> Void
    var onEnded: (CGSize) -> Void

    func makeUIView(context: Context) -> TrackingControl {
        let control = TrackingControl()
        control.backgroundColor = .clear
        control.isMultipleTouchEnabled = false
        return control
    }

    func updateUIView(_ uiView: TrackingControl, context: Context) {
        uiView.activeHitHeight = activeHitHeight
        uiView.onBegan = onBegan
        uiView.onMoved = onMoved
        uiView.onEnded = onEnded
    }

    final class TrackingControl: UIControl {
        var onBegan: (() -> Void)?
        var onMoved: ((CGSize) -> Void)?
        var onEnded: ((CGSize) -> Void)?
        var activeHitHeight: CGFloat = 54
        private var startPoint: CGPoint?
        private var latestTranslation = CGSize.zero

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let minY = max(0, bounds.maxY - activeHitHeight)
            return point.x >= bounds.minX && point.x <= bounds.maxX && point.y >= minY && point.y <= bounds.maxY
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            startPoint = touch.location(in: self)
            latestTranslation = .zero
            onBegan?()
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard let startPoint else { return true }
            let point = touch.location(in: self)
            latestTranslation = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            onMoved?(latestTranslation)
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            if let touch, let startPoint {
                let point = touch.location(in: self)
                latestTranslation = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            }
            onEnded?(latestTranslation)
            resetTracking()
        }

        override func cancelTracking(with event: UIEvent?) {
            onEnded?(latestTranslation)
            resetTracking()
        }

        private func resetTracking() {
            startPoint = nil
            latestTranslation = .zero
        }
    }
}

private struct VoiceWaveformView: View {
    private let bars = Array(0..<18)

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(bars, id: \.self) { index in
                    let phase = time * 5.2 + Double(index) * 0.48
                    let normalized = (sin(phase) + 1) / 2
                    Capsule()
                        .fill(Color.mindInk.opacity(0.72))
                        .frame(width: 3, height: 8 + normalized * 22)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private enum LiquidGlassShape {
    case circle
    case capsule
    case roundedRectangle(cornerRadius: CGFloat)
}

private struct LiquidGlassPressState: Equatable {
    var isPressed = false
    var translation = CGSize.zero
}

private struct LiquidGlassControl<Label: View>: View {
    let size: CGFloat
    let shape: LiquidGlassShape
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @GestureState private var pressState = LiquidGlassPressState()

    var body: some View {
        ZStack {
            Color.clear
                .modifier(LiquidGlassSurface(shape: shape, isActive: isActive || pressState.isPressed))

            label()
        }
        .frame(width: size, height: size)
        .scaleEffect(x: glassXScale, y: glassYScale)
        .rotationEffect(.degrees(glassRotation))
        .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.50, blendDuration: 0.06), value: pressState)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($pressState) { value, state, _ in
                    state.isPressed = true
                    state.translation = value.translation
                }
                .onEnded { value in
                    guard abs(value.translation.width) < size * 0.72,
                          abs(value.translation.height) < size * 0.72 else { return }
                    action()
                }
        )
    }

    private var glassXScale: CGFloat {
        guard pressState.isPressed else { return 1 }
        let horizontalPull = min(abs(pressState.translation.width) / size, 1)
        let verticalPull = min(abs(pressState.translation.height) / size, 1)
        return 0.94 + horizontalPull * 0.18 - verticalPull * 0.05
    }

    private var glassYScale: CGFloat {
        guard pressState.isPressed else { return 1 }
        let horizontalPull = min(abs(pressState.translation.width) / size, 1)
        let verticalPull = min(abs(pressState.translation.height) / size, 1)
        return 0.94 + verticalPull * 0.16 - horizontalPull * 0.05
    }

    private var glassRotation: Double {
        guard pressState.isPressed else { return 0 }
        return Double(max(min(pressState.translation.width / size, 1), -1) * 3)
    }
}

private struct LiquidGlassSurface: ViewModifier {
    let shape: LiquidGlassShape
    let isActive: Bool

    func body(content: Content) -> some View {
        switch shape {
        case .circle:
            content
                .background { glassBackground(Circle()) }
                .clipShape(Circle())
        case .capsule:
            content
                .background { glassBackground(Capsule()) }
                .clipShape(Capsule())
        case .roundedRectangle(let cornerRadius):
            content
                .background { glassBackground(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private func glassBackground<S: InsettableShape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: shape)
                .shadow(color: .white.opacity(isActive ? 0.16 : 0.08), radius: isActive ? 7 : 4, y: -1)
                .shadow(color: .black.opacity(isActive ? 0.13 : 0.10), radius: isActive ? 12 : 9, y: 6)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .shadow(color: .white.opacity(isActive ? 0.16 : 0.08), radius: isActive ? 7 : 4, y: -1)
                .shadow(color: .black.opacity(isActive ? 0.13 : 0.10), radius: isActive ? 12 : 9, y: 6)
        }
    }
}

struct SectionHeader: View {
    var eyebrow: String? = nil
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.mindInk.opacity(0.38))
            }
            Text(title)
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(Color.mindInk)
        }
    }
}

extension Color {
    static let mindInk = adaptive(
        light: UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1),
        dark: UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1)
    )
    static let mindAccent = adaptive(
        light: UIColor(red: 0.19, green: 0.45, blue: 0.82, alpha: 1),
        dark: UIColor(red: 0.40, green: 0.64, blue: 0.98, alpha: 1)
    )
    static let primaryButtonSurface = adaptive(
        light: UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1),
        dark: UIColor(red: 0.24, green: 0.28, blue: 0.34, alpha: 1)
    )
    static let softMint = adaptive(
        light: UIColor(red: 0.93, green: 0.97, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.13, blue: 0.14, alpha: 1)
    )
    static let appCanvas = adaptive(
        light: UIColor(red: 0.985, green: 0.986, blue: 0.982, alpha: 1),
        dark: UIColor(red: 0.055, green: 0.060, blue: 0.070, alpha: 1)
    )
    static let warmPaper = adaptive(
        light: UIColor(red: 0.985, green: 0.986, blue: 0.982, alpha: 1),
        dark: UIColor(red: 0.09, green: 0.095, blue: 0.105, alpha: 1)
    )
    static let cardSurface = adaptive(
        light: UIColor.white,
        dark: UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
    )
    static let controlSurface = adaptive(
        light: UIColor.black.withAlphaComponent(0.035),
        dark: UIColor.white.withAlphaComponent(0.085)
    )
    static let separatorLine = adaptive(
        light: UIColor.black.withAlphaComponent(0.055),
        dark: UIColor.white.withAlphaComponent(0.10)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

extension View {
    func enableNavigationSwipeBack() -> some View {
        background(NavigationSwipeBackEnabler())
    }

    func animateTabBarReturnWhenDisappearing(shouldAnimate: Bool) -> some View {
        background(TabBarReturnAnimator(shouldAnimate: shouldAnimate))
    }

    func animateTabBarVisibility(isHidden: Bool) -> some View {
        background(TabBarVisibilityAnimator(isHidden: isHidden))
    }
}

private struct NavigationSwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.coordinator = context.coordinator
        uiViewController.enableSwipeBack()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Controller: UIViewController {
        weak var coordinator: Coordinator?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableSwipeBack()
        }

        func enableSwipeBack() {
            guard let navigationController else { return }
            coordinator?.navigationController = navigationController
            navigationController.interactivePopGestureRecognizer?.delegate = coordinator
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

private struct TabBarReturnAnimator: UIViewControllerRepresentable {
    let shouldAnimate: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        context.coordinator.shouldAnimate = shouldAnimate
        uiViewController.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var shouldAnimate = false
    }

    final class Controller: UIViewController {
        weak var coordinator: Coordinator?

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard coordinator?.shouldAnimate == true else { return }
            animateTabBarIn()
        }

        private func animateTabBarIn() {
            guard let tabBar = tabBarController?.tabBar else { return }

            tabBar.layer.removeAllAnimations()
            tabBar.isHidden = false

            UIView.performWithoutAnimation {
                tabBar.alpha = 0
                tabBar.transform = CGAffineTransform(translationX: 0, y: 18)
                tabBar.layoutIfNeeded()
            }

            let animations = {
                tabBar.alpha = 1
                tabBar.transform = .identity
            }

            if let transitionCoordinator {
                transitionCoordinator.animate { _ in
                    animations()
                } completion: { context in
                    if context.isCancelled {
                        tabBar.alpha = 0
                        tabBar.transform = CGAffineTransform(translationX: 0, y: 18)
                    } else {
                        tabBar.isHidden = false
                        tabBar.alpha = 1
                        tabBar.transform = .identity
                    }
                }
            } else {
                UIView.animate(
                    withDuration: 0.30,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction],
                    animations: animations
                ) { _ in
                    tabBar.isHidden = false
                    tabBar.alpha = 1
                    tabBar.transform = .identity
                }
            }
        }
    }
}

private struct TabBarVisibilityAnimator: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.coordinator = context.coordinator
        uiViewController.setTabBarHidden(isHidden, animated: context.coordinator.hasAppliedState)
        context.coordinator.hasAppliedState = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var hasAppliedState = false
    }

    final class Controller: UIViewController {
        weak var coordinator: Coordinator?
        private var requestedHidden = false
        private var appliedHidden: Bool?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyTabBarVisibility(animated: false)
        }

        func setTabBarHidden(_ hidden: Bool, animated: Bool) {
            requestedHidden = hidden
            guard appliedHidden != hidden else { return }
            appliedHidden = hidden
            applyTabBarVisibility(animated: animated)
        }

        private func applyTabBarVisibility(animated: Bool) {
            guard let tabBar = resolvedTabBar() else { return }
            tabBar.layer.removeAllAnimations()

            let duration = animated ? 0.24 : 0

            if requestedHidden {
                tabBar.isHidden = false
                tabBar.isUserInteractionEnabled = false
                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                    animations: {
                        tabBar.alpha = 0
                    },
                    completion: { _ in
                        guard self.requestedHidden else { return }
                        tabBar.isHidden = false
                        tabBar.isUserInteractionEnabled = false
                        tabBar.alpha = 0
                    }
                )
            } else {
                tabBar.isHidden = false
                tabBar.isUserInteractionEnabled = true

                if animated {
                    UIView.performWithoutAnimation {
                        tabBar.alpha = 0
                        tabBar.transform = CGAffineTransform(translationX: 0, y: 18)
                        tabBar.layoutIfNeeded()
                    }
                }

                UIView.animate(
                    withDuration: animated ? 0.30 : duration,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
                    animations: {
                        tabBar.alpha = 1
                        tabBar.transform = .identity
                    },
                    completion: { _ in
                        guard !self.requestedHidden else { return }
                        tabBar.isHidden = false
                        tabBar.isUserInteractionEnabled = true
                        tabBar.alpha = 1
                        tabBar.transform = .identity
                    }
                )
            }
        }

        private func resolvedTabBar() -> UITabBar? {
            if let tabBar = tabBarController?.tabBar {
                return tabBar
            }
            if let tabBar = parentTabBarController(from: self)?.tabBar {
                return tabBar
            }
            if let tabBar = view.window?.rootViewController?.nearestTabBarController()?.tabBar {
                return tabBar
            }
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: { $0.isKeyWindow })?
                .rootViewController?
                .nearestTabBarController()?
                .tabBar
        }

        private func parentTabBarController(from controller: UIViewController?) -> UITabBarController? {
            var current = controller
            while let controller = current {
                if let tabBarController = controller as? UITabBarController {
                    return tabBarController
                }
                if let tabBarController = controller.tabBarController {
                    return tabBarController
                }
                current = controller.parent
            }
            return nil
        }
    }
}

private extension UIViewController {
    func nearestTabBarController() -> UITabBarController? {
        if let tabBarController = self as? UITabBarController {
            return tabBarController
        }
        if let tabBarController {
            return tabBarController
        }
        for child in children {
            if let tabBarController = child.nearestTabBarController() {
                return tabBarController
            }
        }
        return presentedViewController?.nearestTabBarController()
    }
}
