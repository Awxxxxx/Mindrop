import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var noteAnimationRunID = 0
    @State private var editingNote: ThoughtNote?
    @State private var billSort: BillSortOption = .latest
    @State private var billTimeFilter: BillTimeFilter = .all
    @State private var billAmountFilter: BillAmountFilter = .all
    @State private var billTypeFilter: ExpenseCategory?
    @State private var openSwipeNoteID: UUID?
    @State private var scrollContentMaxY: CGFloat = 0
    @State private var lastScrollContentMinY: CGFloat?
    @State private var noteRowFrames: [UUID: CGRect] = [:]

    private static let scrollCoordinateSpace = "HistoryScrollCoordinateSpace"
    private static let viewCoordinateSpace = "HistoryViewCoordinateSpace"

    private var visibleNotes: [ThoughtNote] {
        store.notes
            .filter { $0.category == store.selectedCategory }
            .filter(applyBillFilters)
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                switch store.selectedCategory {
                case .todo:
                    return lhs.createdAt > rhs.createdAt
                case .bill:
                    return billSort.compare(lhs, rhs)
                default:
                    return lhs.createdAt > rhs.createdAt
                }
            }
    }

    var body: some View {
        ZStack {
            Color.appCanvas.ignoresSafeArea()

            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 17) {
                            header
                            categories

                            if store.selectedCategory == .bill {
                                billFilters
                            }

                            if store.selectedCategory == .recycleBin {
                                recycleBinNotice
                            }

                            noteList
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 48)
                        .padding(.bottom, 34)
                        .background(scrollContentBoundsReader)
                    }
                    .coordinateSpace(name: Self.scrollCoordinateSpace)

                    blankAreaDismissOverlay(viewportHeight: proxy.size.height)
                }
            }

            globalSwipeActionHitOverlay
        }
        .coordinateSpace(name: Self.viewCoordinateSpace)
        .onPreferenceChange(HistoryScrollContentMinYPreferenceKey.self) { value in
            dismissSwipeMenuIfScrolled(to: value)
        }
        .onPreferenceChange(HistoryScrollContentMaxYPreferenceKey.self) { value in
            scrollContentMaxY = value
        }
        .onPreferenceChange(NoteRowFramePreferenceKey.self) { value in
            noteRowFrames = value
        }
        .sheet(item: $editingNote) { note in
            NoteEditorView(note: note)
                .presentationDetents([.large])
                .presentationCornerRadius(28)
        }
        .onAppear {
            store.recycleExpiredReminders()
            store.purgeExpiredRecycleBinNotes()
            replayNoteAnimations()
        }
        .onChange(of: store.selectedCategory) { _, category in
            resetBillFilters()
            if category == .todo {
                store.recycleExpiredReminders()
            }
            if category == .recycleBin {
                store.purgeExpiredRecycleBinNotes()
            }
            replayNoteAnimations()
        }
        .onChange(of: store.selectedTab) { _, tab in
            guard tab == .history else { return }
            replayNoteAnimations()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            SectionHeader(title: "历史")
            Spacer()
            IconCircleButton(systemName: "plus") {
                store.selectedTab = .input
            }
        }
    }

    @ViewBuilder
    private var noteList: some View {
        if visibleNotes.isEmpty {
            emptyState
        } else if store.selectedCategory == .bill {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(billDaySections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.mindInk.opacity(0.56))
                            .padding(.horizontal, 4)

                        ForEach(section.notes) { indexedNote in
                            noteCard(note: indexedNote.note, index: indexedNote.index)
                        }
                    }
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: visibleNoteLayoutKey)
        } else {
            LazyVStack(spacing: 14) {
                ForEach(Array(visibleNotes.enumerated()), id: \.element.id) { index, note in
                    noteCard(note: note, index: index)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: visibleNoteLayoutKey)
        }
    }

    private func noteCard(note: ThoughtNote, index: Int) -> some View {
        SwipeableNoteCardView(
            note: note,
            index: index,
            animationRunID: noteAnimationRunID,
            openSwipeNoteID: $openSwipeNoteID,
            actions: swipeActions(for: note),
            contextMenu: {
                contextActions(for: note)
            },
            onTap: {
                editingNote = note
            }
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: NoteRowFramePreferenceKey.self,
                    value: [note.id: proxy.frame(in: .named(Self.viewCoordinateSpace))]
                )
            }
        }
        .zIndex(openSwipeNoteID == note.id ? 100 : 0)
    }

    @ViewBuilder
    private var globalSwipeActionHitOverlay: some View {
        if let openSwipeNoteID,
           let note = store.notes.first(where: { $0.id == openSwipeNoteID }),
           let frame = noteRowFrames[openSwipeNoteID] {
            let actions = swipeActions(for: note)
            let actionWidth: CGFloat = 76
            let revealWidth = CGFloat(actions.count) * actionWidth

            HStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { _, item in
                    Color.black.opacity(0.001)
                        .frame(width: actionWidth, height: frame.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            self.openSwipeNoteID = nil
                            item.action()
                        }
                }
            }
            .frame(width: revealWidth, height: frame.height)
            .position(x: frame.maxX - revealWidth / 2, y: frame.midY)
            .zIndex(998)
        }
    }

    private var visibleNoteLayoutKey: [String] {
        visibleNotes.map { "\($0.id.uuidString)-\($0.isPinned)-\($0.category.rawValue)" }
    }

    private var billDaySections: [BillDaySection] {
        let calendar = Calendar.current
        let notesByDay = Dictionary(grouping: visibleNotes) { note in
            calendar.startOfDay(for: note.createdAt)
        }
        let days = notesByDay.keys.sorted { lhs, rhs in
            billSort == .oldest ? lhs < rhs : lhs > rhs
        }

        var displayIndex = 0
        return days.map { day in
            let notes = notesByDay[day, default: []].map { note in
                let indexedNote = IndexedNote(index: displayIndex, note: note)
                displayIndex += 1
                return indexedNote
            }
            return BillDaySection(day: day, title: billDayTitle(for: day), notes: notes)
        }
    }

    private func billDayTitle(for date: Date) -> String {
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

    private func replayNoteAnimations() {
        openSwipeNoteID = nil
        noteAnimationRunID += 1
    }

    private var scrollContentBoundsReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: HistoryScrollContentMinYPreferenceKey.self,
                    value: proxy.frame(in: .named(Self.scrollCoordinateSpace)).minY
                )
                .preference(
                    key: HistoryScrollContentMaxYPreferenceKey.self,
                    value: proxy.frame(in: .named(Self.scrollCoordinateSpace)).maxY
                )
        }
    }

    @ViewBuilder
    private func blankAreaDismissOverlay(viewportHeight: CGFloat) -> some View {
        let top = max(0, min(scrollContentMaxY, viewportHeight))
        let height = max(0, viewportHeight - top)
        if openSwipeNoteID != nil, height > 1 {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
                .offset(y: top)
                .onTapGesture {
                    closeOpenSwipeMenu()
                }
        }
    }

    private func closeOpenSwipeMenu() {
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.12)) {
            openSwipeNoteID = nil
        }
    }

    private func dismissSwipeMenuIfScrolled(to minY: CGFloat) {
        defer {
            lastScrollContentMinY = minY
        }

        guard openSwipeNoteID != nil, let lastScrollContentMinY else { return }
        if abs(minY - lastScrollContentMinY) > 1 {
            closeOpenSwipeMenu()
        }
    }

    private var categories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ThoughtCategory.allCases) { category in
                    Button {
                        store.selectedCategory = category
                    } label: {
                        Text(category.rawValue)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(category == store.selectedCategory ? Color.mindInk.opacity(0.76) : Color.mindInk.opacity(0.46))
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(
                                category == store.selectedCategory ? category.noteColor.opacity(0.20) : Color.controlSurface,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    private var billFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(BillSortOption.allCases) { option in
                        Button(option.rawValue) { billSort = option }
                    }
                } label: {
                    filterChip(title: "排序", value: billSort.rawValue)
                }

                Menu {
                    ForEach(BillTimeFilter.allCases) { option in
                        Button(option.rawValue) { billTimeFilter = option }
                    }
                } label: {
                    filterChip(title: "时间", value: billTimeFilter.rawValue)
                }

                Menu {
                    ForEach(BillAmountFilter.allCases) { option in
                        Button(option.rawValue) { billAmountFilter = option }
                    }
                } label: {
                    filterChip(title: "金额", value: billAmountFilter.rawValue)
                }

                Menu {
                    Button("全部") { billTypeFilter = nil }
                    ForEach(ExpenseCategory.allCases) { option in
                        Button(option.rawValue) { billTypeFilter = option }
                    }
                } label: {
                    filterChip(title: "类型", value: billTypeFilter?.rawValue ?? "全部")
                }
            }
        }
        .scrollClipDisabled()
    }

    private var recycleBinNotice: some View {
        Text("进入回收站7天后将彻底删除")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.mindInk.opacity(0.46))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func contextActions(for note: ThoughtNote) -> some View {
        if note.category == .recycleBin {
            Button("还原") { store.restore(note) }
            Button("永久删除", role: .destructive) { store.deletePermanently(note) }
        } else {
            Button("删除", role: .destructive) { delete(note) }
            Button("编辑") { editingNote = note }
            Button(note.isPinned ? "取消置顶" : "置顶") { togglePin(note) }
            Menu("移动") {
                ForEach(ThoughtCategory.allCases.filter { $0 != .recycleBin && $0 != note.category }) { category in
                    Button(category.rawValue) { move(note, to: category) }
                }
            }
        }
    }

    private func swipeActions(for note: ThoughtNote) -> [NoteSwipeAction] {
        if note.category == .recycleBin {
            return [
                NoteSwipeAction(title: "还原", systemName: "arrow.uturn.backward", tint: .orange) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        store.restore(note)
                    }
                },
                NoteSwipeAction(title: "删除", systemName: "trash", tint: .red) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        store.deletePermanently(note)
                    }
                }
            ]
        } else {
            return [
                NoteSwipeAction(title: note.isPinned ? "取消置顶" : "置顶", systemName: note.isPinned ? "pin.slash" : "pin", tint: .orange) {
                    togglePin(note)
                },
                NoteSwipeAction(title: "删除", systemName: "trash", tint: .red) {
                    delete(note)
                }
            ]
        }
    }

    private func delete(_ note: ThoughtNote) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            store.moveToRecycleBin(note)
        }
    }

    private func togglePin(_ note: ThoughtNote) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            store.pin(note)
        }
    }

    private func move(_ note: ThoughtNote, to category: ThoughtCategory) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            store.move(note, to: category)
        }
    }

    private func resetBillFilters() {
        billTimeFilter = .all
        billAmountFilter = .all
        billTypeFilter = nil
    }

    private func filterChip(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(Color.mindInk.opacity(0.42))
            Text(value)
                .foregroundStyle(Color.mindInk.opacity(0.72))
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.mindInk.opacity(0.38))
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(Color.controlSurface, in: Capsule())
    }

    private func applyBillFilters(_ note: ThoughtNote) -> Bool {
        guard store.selectedCategory == .bill else { return true }
        guard billTimeFilter.contains(note.createdAt) else { return false }
        guard billAmountFilter.contains(note.expenseAmount) else { return false }
        if let billTypeFilter {
            return note.expenseCategory == billTypeFilter
        }
        return true
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(Color.mindInk.opacity(0.34))
            Text("这里还没有便签")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.mindInk.opacity(0.44))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct AnimatedNoteCardView: View {
    let note: ThoughtNote
    let index: Int
    let animationRunID: Int

    @State private var isVisible = false
    @State private var activeAnimationRunID = 0

    var body: some View {
        NoteCardView(note: note)
            .offset(y: isVisible ? 0 : 22)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                playAnimation(for: animationRunID)
            }
            .onChange(of: animationRunID) { _, newValue in
                playAnimation(for: newValue)
            }
    }

    private func playAnimation(for runID: Int) {
        activeAnimationRunID = runID

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + Double(index) * 0.05) {
            guard activeAnimationRunID == runID else { return }
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
                isVisible = true
            }
        }
    }
}

private struct SwipeableNoteCardView<ContextMenuContent: View>: View {
    let note: ThoughtNote
    let index: Int
    let animationRunID: Int
    @Binding var openSwipeNoteID: UUID?
    let actions: [NoteSwipeAction]
    @ViewBuilder let contextMenu: () -> ContextMenuContent
    let onTap: () -> Void

    @State private var isVisible = false
    @State private var activeAnimationRunID = 0

    var body: some View {
        NoteCardView(note: note)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                UIKitSwipeNoteRow(
                    note: note,
                    openSwipeNoteID: $openSwipeNoteID,
                    actions: actions,
                    contextMenu: contextMenu,
                    onTap: onTap
                )
            }
            .offset(y: isVisible ? 0 : 22)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                playAnimation(for: animationRunID)
            }
            .onChange(of: animationRunID) { _, newValue in
                playAnimation(for: newValue)
            }
            .onChange(of: note.id) { _, _ in
                openSwipeNoteID = nil
            }
    }

    private func playAnimation(for runID: Int) {
        activeAnimationRunID = runID

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + Double(index) * 0.05) {
            guard activeAnimationRunID == runID else { return }
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
                isVisible = true
            }
        }
    }
}

private struct UIKitSwipeNoteRow<ContextMenuContent: View>: UIViewRepresentable {
    let note: ThoughtNote
    @Binding var openSwipeNoteID: UUID?
    let actions: [NoteSwipeAction]
    @ViewBuilder let contextMenu: () -> ContextMenuContent
    let onTap: () -> Void

    private let actionWidth: CGFloat = 76

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SwipeNoteRowContainer {
        let view = SwipeNoteRowContainer(actionWidth: actionWidth)
        view.onActionTap = { [weak coordinator = context.coordinator] index in
            coordinator?.performAction(at: index)
        }
        view.onCardTap = { [weak coordinator = context.coordinator] in
            coordinator?.handleCardTap()
        }
        view.onSwipeBegan = { [weak coordinator = context.coordinator] in
            coordinator?.parent.openSwipeNoteID = nil
        }
        view.onSwipeProgress = { [weak coordinator = context.coordinator] offsetX in
            guard let coordinator else { return }
            if offsetX > actionWidth * 0.35 {
                coordinator.parent.openSwipeNoteID = coordinator.parent.note.id
            }
        }
        view.onSwipeSettled = { [weak coordinator = context.coordinator] isOpen in
            coordinator?.parent.openSwipeNoteID = isOpen ? coordinator?.parent.note.id : nil
        }
        context.coordinator.rowView = view
        context.coordinator.installCard(in: view)
        view.configureActions(actions)
        return view
    }

    func updateUIView(_ uiView: SwipeNoteRowContainer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.installCard(in: uiView)
        uiView.configureActions(actions)
        guard !uiView.isPanning else { return }
        uiView.setOpen(openSwipeNoteID == note.id, animated: true)
    }

    final class Coordinator {
        var parent: UIKitSwipeNoteRow
        weak var rowView: SwipeNoteRowContainer?
        private var cardHost: UIHostingController<AnyView>?

        init(_ parent: UIKitSwipeNoteRow) {
            self.parent = parent
        }

        func installCard(in rowView: SwipeNoteRowContainer) {
            let card = AnyView(
                NoteCardView(note: parent.note)
                    .contextMenu {
                        parent.contextMenu()
                    }
            )

            if let cardHost {
                cardHost.rootView = card
            } else {
                let host = UIHostingController(rootView: card)
                host.view.backgroundColor = .clear
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                rowView.cardContentView.addSubview(host.view)
                cardHost = host
            }
            rowView.setNeedsLayout()
        }

        func handleCardTap() {
            guard let rowView else { return }
            if rowView.isOpen || parent.openSwipeNoteID != nil {
                parent.openSwipeNoteID = nil
                rowView.setOpen(false, animated: true)
            } else {
                parent.onTap()
            }
        }

        func performAction(at index: Int) {
            guard parent.actions.indices.contains(index), let rowView else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            parent.openSwipeNoteID = nil
            rowView.setOpen(false, animated: true)
            parent.actions[index].action()
        }
    }
}

private final class SwipeNoteRowContainer: UIView, UIGestureRecognizerDelegate {
    let actionWidth: CGFloat
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    let cardContentView = UIView()
    private let actionsContainerView = UIView()
    private let actionsStackView = UIStackView()
    private let actionHitStackView = UIStackView()

    var onActionTap: ((Int) -> Void)?
    var onCardTap: (() -> Void)?
    var onSwipeBegan: (() -> Void)?
    var onSwipeProgress: ((CGFloat) -> Void)?
    var onSwipeSettled: ((Bool) -> Void)?
    private(set) var revealWidth: CGFloat = 0

    private var isPanningInternal = false
    private var panStartOffsetX: CGFloat = 0
    private var didMoveHorizontally = false

    var isOpen: Bool {
        scrollView.contentOffset.x > revealWidth * 0.5
    }

    var isPanning: Bool {
        isPanningInternal
    }

    init(actionWidth: CGFloat) {
        self.actionWidth = actionWidth
        super.init(frame: .zero)
        clipsToBounds = true
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = false
        scrollView.isScrollEnabled = false
        scrollView.backgroundColor = .clear
        addSubview(scrollView)

        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)

        actionsContainerView.clipsToBounds = true
        actionsContainerView.layer.cornerRadius = 14
        actionsContainerView.layer.cornerCurve = .continuous
        contentView.addSubview(actionsContainerView)

        actionsStackView.axis = .horizontal
        actionsStackView.alignment = .fill
        actionsStackView.distribution = .fillEqually
        actionsContainerView.addSubview(actionsStackView)

        cardContentView.backgroundColor = .clear
        contentView.addSubview(cardContentView)

        actionHitStackView.axis = .horizontal
        actionHitStackView.alignment = .fill
        actionHitStackView.distribution = .fillEqually
        actionHitStackView.backgroundColor = .clear
        actionHitStackView.isHidden = true
        addSubview(actionHitStackView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCardTap))
        cardContentView.addGestureRecognizer(tap)

        let actionTap = UITapGestureRecognizer(target: self, action: #selector(handleRowActionTap(_:)))
        actionTap.delegate = self
        actionTap.cancelsTouchesInView = true
        addGestureRecognizer(actionTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = true
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        contentView.frame = CGRect(x: 0, y: 0, width: bounds.width + revealWidth, height: bounds.height)
        scrollView.contentSize = contentView.bounds.size
        cardContentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        actionsContainerView.frame = CGRect(x: bounds.width, y: 0, width: revealWidth, height: bounds.height)
        actionsStackView.frame = CGRect(x: 0, y: 0, width: revealWidth, height: bounds.height)
        actionHitStackView.frame = CGRect(x: bounds.width - revealWidth, y: 0, width: revealWidth, height: bounds.height)
        cardContentView.subviews.first?.frame = cardContentView.bounds
        clampContentOffset()
        updateActionHitTargets()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if actionTapFrame.contains(point) {
            return self
        }
        return super.hitTest(point, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !didMoveHorizontally, let point = touches.first?.location(in: self), actionTapFrame.contains(point) else {
            super.touchesEnded(touches, with: event)
            didMoveHorizontally = false
            return
        }

        let localX = point.x - actionTapFrame.minX
        let index = min(max(Int(localX / actionWidth), 0), max(actionHitStackView.arrangedSubviews.count - 1, 0))
        didMoveHorizontally = false
        onActionTap?(index)
    }

    func configureActions(_ actions: [NoteSwipeAction]) {
        revealWidth = CGFloat(actions.count) * actionWidth

        if actionsStackView.arrangedSubviews.count != actions.count {
            actionsStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            actionHitStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for index in actions.indices {
                let actionView = UIView()
                actionView.tag = index
                actionView.isUserInteractionEnabled = true
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleActionTap(_:)))
                tap.cancelsTouchesInView = false
                actionView.addGestureRecognizer(tap)
                actionsStackView.addArrangedSubview(actionView)

                let hitView = UIView()
                hitView.tag = index
                hitView.backgroundColor = .clear
                hitView.isUserInteractionEnabled = true
                let hitTap = UITapGestureRecognizer(target: self, action: #selector(handleActionTap(_:)))
                hitTap.cancelsTouchesInView = true
                hitView.addGestureRecognizer(hitTap)
                actionHitStackView.addArrangedSubview(hitView)
            }
        }

        for (index, view) in actionsStackView.arrangedSubviews.enumerated() {
            guard index < actions.count else { continue }
            configureActionView(view, with: actions[index], index: index, count: actions.count)
        }
        setNeedsLayout()
    }

    func setOpen(_ isOpen: Bool, animated: Bool) {
        let targetX = isOpen ? revealWidth : 0
        guard abs(scrollView.contentOffset.x - targetX) > 0.5 else { return }

        if animated {
            UIView.animate(
                withDuration: 0.35,
                delay: 0,
                usingSpringWithDamping: 0.78,
                initialSpringVelocity: 0,
                options: [.curveEaseOut, .allowUserInteraction],
                animations: {
                    self.scrollView.contentOffset = CGPoint(x: targetX, y: 0)
                    self.updateActionHitTargets()
                }
            )
        } else {
            scrollView.contentOffset = CGPoint(x: targetX, y: 0)
            updateActionHitTargets()
        }
    }

    @objc private func handleCardTap() {
        onCardTap?()
    }

    @objc private func handleActionTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let view = recognizer.view else { return }
        onActionTap?(view.tag)
    }

    @objc private func handleRowActionTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        performActionTap(at: recognizer.location(in: self))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        let velocity = recognizer.velocity(in: self)

        switch recognizer.state {
        case .began:
            isPanningInternal = true
            didMoveHorizontally = false
            panStartOffsetX = scrollView.contentOffset.x
            scrollView.layer.removeAllAnimations()
            onSwipeBegan?()
        case .changed:
            if abs(translation.x) > 8 {
                didMoveHorizontally = true
            }
            let rawOffsetX = panStartOffsetX - translation.x
            let clampedOffsetX = min(max(rawOffsetX, 0), revealWidth)
            scrollView.contentOffset = CGPoint(x: clampedOffsetX, y: 0)
            updateActionHitTargets()
            onSwipeProgress?(clampedOffsetX)
        case .ended, .cancelled, .failed:
            let shouldOpen: Bool
            if velocity.x < -350 {
                shouldOpen = true
            } else if velocity.x > 350 {
                shouldOpen = false
            } else {
                shouldOpen = scrollView.contentOffset.x > revealWidth * 0.42
            }
            isPanningInternal = false
            setOpen(shouldOpen, animated: true)
            onSwipeSettled?(shouldOpen)
        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y)
        }

        if gestureRecognizer is UITapGestureRecognizer {
            let point = gestureRecognizer.location(in: self)
            return actionTapFrame.contains(point)
        }

        return true
    }

    private func configureActionView(_ view: UIView, with action: NoteSwipeAction, index: Int, count: Int) {
        view.subviews.forEach { $0.removeFromSuperview() }
        view.backgroundColor = UIColor(action.tint)
        view.clipsToBounds = true
        view.layer.cornerRadius = 14
        view.layer.cornerCurve = .continuous
        view.layer.maskedCorners = roundedCorners(for: index, count: count)
        view.accessibilityLabel = action.title
        view.accessibilityTraits = .button

        let imageView = UIImageView(image: UIImage(systemName: action.systemName))
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = action.title
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.72

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 5
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -4)
        ])
    }

    private func roundedCorners(for index: Int, count: Int) -> CACornerMask {
        guard count > 1 else {
            return [
                .layerMinXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMinYCorner,
                .layerMaxXMaxYCorner
            ]
        }

        if index == 0 {
            return [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        } else if index == count - 1 {
            return [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        } else {
            return []
        }
    }

    private func clampContentOffset() {
        let maxOffsetX = max(0, revealWidth)
        let clampedX = min(max(scrollView.contentOffset.x, 0), maxOffsetX)
        if abs(scrollView.contentOffset.x - clampedX) > 0.5 {
            scrollView.contentOffset.x = clampedX
        }
        updateActionHitTargets()
    }

    private func updateActionHitTargets() {
        actionHitStackView.isHidden = scrollView.contentOffset.x < revealWidth * 0.72
    }

    private var actionTapFrame: CGRect {
        guard scrollView.contentOffset.x >= revealWidth * 0.72, revealWidth > 0 else {
            return .null
        }
        return CGRect(x: bounds.width - revealWidth, y: 0, width: revealWidth, height: bounds.height)
    }

    private func performActionTap(at point: CGPoint) {
        guard actionTapFrame.contains(point), actionWidth > 0 else {
            return
        }
        let localX = point.x - actionTapFrame.minX
        let index = min(max(Int(localX / actionWidth), 0), max(actionHitStackView.arrangedSubviews.count - 1, 0))
        onActionTap?(index)
    }
}

private struct NoteSwipeAction: Identifiable {
    let id = UUID()
    let title: String
    let systemName: String
    let tint: Color
    let action: () -> Void
}

private struct HistoryScrollContentMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HistoryScrollContentMaxYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NoteRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct BillDaySection: Identifiable {
    let day: Date
    let title: String
    let notes: [IndexedNote]

    var id: Date { day }
}

private struct IndexedNote: Identifiable {
    let index: Int
    let note: ThoughtNote

    var id: UUID { note.id }
}

private enum BillSortOption: String, CaseIterable, Identifiable {
    case latest = "最新"
    case oldest = "最早"
    case amountHigh = "金额高"
    case amountLow = "金额低"

    var id: String { rawValue }

    func compare(_ lhs: ThoughtNote, _ rhs: ThoughtNote) -> Bool {
        switch self {
        case .latest:
            return lhs.createdAt > rhs.createdAt
        case .oldest:
            return lhs.createdAt < rhs.createdAt
        case .amountHigh:
            return lhs.expenseAmount.doubleValue > rhs.expenseAmount.doubleValue
        case .amountLow:
            return lhs.expenseAmount.doubleValue < rhs.expenseAmount.doubleValue
        }
    }
}

private enum BillTimeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case seven = "近7天"
    case thirty = "近30天"
    case year = "近1年"

    var id: String { rawValue }

    func contains(_ date: Date) -> Bool {
        switch self {
        case .all:
            return true
        case .seven:
            return date >= Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        case .thirty:
            return date >= Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        case .year:
            return date >= Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
        }
    }
}

private enum BillAmountFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case under100 = "100内"
    case between100And1000 = "100-1000"
    case between1000And5000 = "1000-5000"
    case between5000And10000 = "5000-1万"
    case over10000 = "1万以上"

    var id: String { rawValue }

    func contains(_ amount: Decimal?) -> Bool {
        guard self != .all else { return true }
        let value = amount.doubleValue
        switch self {
        case .all:
            return true
        case .under100:
            return value < 100
        case .between100And1000:
            return value >= 100 && value < 1000
        case .between1000And5000:
            return value >= 1000 && value < 5000
        case .between5000And10000:
            return value >= 5000 && value < 10000
        case .over10000:
            return value >= 10000
        }
    }
}

private struct NoteEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var note: ThoughtNote
    @State private var hasReminder: Bool
    @State private var amountText: String

    init(note: ThoughtNote) {
        _note = State(initialValue: note)
        _hasReminder = State(initialValue: note.reminderAt != nil)
        _amountText = State(initialValue: note.expenseAmount.amountString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $note.title)
                    TextEditor(text: $note.content)
                        .frame(minHeight: 132)
                }

                Section("分类") {
                    Picker("收纳位置", selection: $note.category) {
                        ForEach(ThoughtCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                }

                if note.category == .todo {
                    Section("提醒") {
                        Toggle("开启提醒", isOn: $hasReminder)
                        if hasReminder {
                            DatePicker(
                                "提醒时间",
                                selection: Binding(
                                    get: { note.reminderAt ?? .now.addingTimeInterval(3600) },
                                    set: { note.reminderAt = $0 }
                                ),
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                    }
                }

                if note.category == .bill {
                    Section("账单") {
                        HStack(spacing: 12) {
                            Text("金额")
                            TextField("0", text: $amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("元")
                                .foregroundStyle(.secondary)
                        }
                        Picker("类型", selection: Binding(
                            get: { note.expenseCategory ?? .other },
                            set: { note.expenseCategory = $0 }
                        )) {
                            ForEach(ExpenseCategory.allCases) { category in
                                Text(category.rawValue).tag(category)
                            }
                        }
                    }
                }
            }
            .navigationTitle("编辑便签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(isSaveDisabled)
                }
            }
        }
    }

    private var isSaveDisabled: Bool {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || (note.category == .bill && Decimal(string: amount) == nil)
    }

    private func save() {
        note.title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.content = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        note.reminderAt = note.category == .todo && hasReminder ? (note.reminderAt ?? .now.addingTimeInterval(3600)) : nil
        note.expenseAmount = note.category == .bill ? Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        note.expenseCategory = note.category == .bill ? (note.expenseCategory ?? .other) : nil
        store.updateNote(note)
        dismiss()
    }
}

private extension Optional where Wrapped == Decimal {
    var doubleValue: Double {
        guard let self else { return 0 }
        return NSDecimalNumber(decimal: self).doubleValue
    }

    var amountString: String {
        guard let self else { return "" }
        return NSDecimalNumber(decimal: self).stringValue
    }
}
