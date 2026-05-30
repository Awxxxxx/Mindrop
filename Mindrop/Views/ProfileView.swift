import SwiftUI
import UIKit
import PhotosUI
import ImageIO

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    let isActive: Bool
    @State private var showSettingsPage = false
    @State private var showProfileEditor = false
    @State private var showWelcomePage = false
    @State private var animateLineChart = true
    @State private var animateDonutCharts = true
    @State private var chartReplayWorkItem: DispatchWorkItem?
    @State private var chartReplayID = 0

    var body: some View {
        NavigationStack {
            profileContent
                .navigationDestination(isPresented: $showSettingsPage) {
                    SettingsPageView(onOpenNotificationSettings: openAppSettings)
                }
                .navigationDestination(isPresented: $showProfileEditor) {
                    ProfileEditorView(animateTabBarReturn: true)
                }
                .navigationDestination(isPresented: $showWelcomePage) {
                    WelcomeView(presentationContext: .profile)
                }
        }
    }

    private var profileContent: some View {
        ZStack {
            Color.appCanvas.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .padding(.bottom, 18)
                    dataHeader
                    thoughtLineCard
                    spendCard
                    distributionCard
                }
                .padding(.horizontal, 22)
                .padding(.top, 76)
                .padding(.bottom, 34)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard isActive else { return }
            replayCharts()
        }
        .onChange(of: isActive) { _, active in
            if active {
                replayCharts()
            } else {
                cancelPendingChartReplay()
            }
        }
        .onChange(of: store.selectedRange) { _, _ in
            guard isActive else { return }
            replayCharts()
        }
    }

    private func openAppSettings() {
        let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString)
            ?? URL(string: UIApplication.openSettingsURLString)
        guard let settingsURL else { return }
        UIApplication.shared.open(settingsURL)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                if store.isLoggedIn {
                    showProfileEditor = true
                } else {
                    showWelcomePage = true
                }
            } label: {
                ProfileAvatar(size: 62)
            }
            .buttonStyle(.plain)

            if store.isLoggedIn {
                profileIdentity
            } else {
                Button {
                    showWelcomePage = true
                } label: {
                    profileIdentity
                }
                .buttonStyle(.plain)
            }

            Spacer()

            IconCircleButton(systemName: "gearshape") {
                showSettingsPage = true
            }
        }
    }

    private var profileIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.isLoggedIn ? store.profile.nickname : "登录/注册")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.mindInk)
            Text(store.isLoggedIn ? "ID \(store.profile.userID)" : "登录后开启云端跨设备同步")
                .font(.footnote)
                .foregroundStyle(Color.mindInk.opacity(0.44))
        }
        .contentShape(Rectangle())
    }

    private var dataHeader: some View {
        HStack(alignment: .center) {
            Text("个人数据")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.mindInk)

            Spacer()

            Picker("时间", selection: $store.selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 172)
        }
    }

    private var thoughtLineCard: some View {
        MetricCard(title: "对话次数：共 \(profileMetrics.conversationTotal) 次", caption: conversationTrendCaption) {
            LineChartView(values: profileMetrics.conversationTrend, progress: animateLineChart ? 1 : 0)
                .frame(height: 132)
        }
    }

    private var conversationTrendCaption: String {
        switch store.selectedRange {
        case .seven:
            return "统计7个自然日"
        case .ninety:
            return "统计13个自然周"
        case .year:
            return "统计12个自然月"
        }
    }

    private var profileMetrics: ProfileMetrics {
        ProfileMetrics.make(
            for: store.selectedRange,
            stats: store.profileStats
        )
    }

    private var spendCard: some View {
        MetricCard(title: "资金支出：共 \(profileMetrics.expenseTotal.formatted()) 元") {
            HStack(spacing: 0) {
                DonutChartView(values: profileMetrics.expenseItems.map(\.percent), colors: profileMetrics.expenseItems.map(\.color), progress: animateDonutCharts ? 1 : 0)
                    .frame(width: 96, height: 96)

                Spacer(minLength: 10)

                ExpenseLegendGrid(items: profileMetrics.expenseItems)
            }
        }
    }

    private var distributionCard: some View {
        MetricCard(title: "类型分布") {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(profileMetrics.distributionItems) { item in
                        LegendRow(color: item.color, title: item.title, value: item.valueText)
                    }
                }

                Spacer()

                DonutChartView(values: profileMetrics.distributionItems.map(\.percent), colors: profileMetrics.distributionItems.map(\.color), progress: animateDonutCharts ? 1 : 0)
                    .frame(width: 96, height: 96)
            }
        }
    }

    private func replayCharts() {
        chartReplayWorkItem?.cancel()
        chartReplayID += 1
        let runID = chartReplayID

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            animateLineChart = false
            animateDonutCharts = false
        }

        let workItem = DispatchWorkItem {
            guard runID == chartReplayID, isActive else { return }
            withAnimation(.easeOut(duration: 1.0)) {
                animateLineChart = true
            }
            withAnimation(.easeOut(duration: 0.85)) {
                animateDonutCharts = true
            }
        }
        chartReplayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: workItem)
    }

    private func cancelPendingChartReplay() {
        chartReplayWorkItem?.cancel()
        chartReplayWorkItem = nil
        chartReplayID += 1
    }
}

private struct ProfileMetrics {
    let conversationTotal: Int
    let conversationTrend: [Int]
    let expenseTotal: Int
    let expenseItems: [ExpenseLegendItem]
    let distributionItems: [DistributionLegendItem]

    static func make(for range: TimeRange, stats: ProfileStats, now: Date = .now) -> ProfileMetrics {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let startDate = metricStartDate(for: range, now: now, calendar: calendar)
        let noteRecords = stats.noteRecords.filter { $0.createdAt >= startDate && $0.createdAt <= now }
        let messageRecords = stats.messageRecords.filter { $0.createdAt >= startDate && $0.createdAt <= now }

        return ProfileMetrics(
            conversationTotal: messageRecords.count,
            conversationTrend: conversationTrend(for: range, messages: messageRecords, startDate: startDate, now: now, calendar: calendar),
            expenseTotal: expenseTotal(from: noteRecords),
            expenseItems: expenseItems(from: noteRecords),
            distributionItems: distributionItems(from: noteRecords)
        )
    }

    private static func conversationTrend(for range: TimeRange, messages: [MessageStatRecord], startDate: Date, now: Date, calendar: Calendar) -> [Int] {
        switch range {
        case .seven:
            return dailyTrend(days: 7, messages: messages, startDate: startDate, calendar: calendar)
        case .ninety:
            return weeklyTrend(weeks: 13, messages: messages, now: now, calendar: calendar)
        case .year:
            return monthlyTrend(messages: messages, now: now, calendar: calendar)
        }
    }

    private static func metricStartDate(for range: TimeRange, now: Date, calendar: Calendar) -> Date {
        switch range {
        case .seven:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .ninety:
            let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            return calendar.date(byAdding: .weekOfYear, value: -12, to: currentWeekStart) ?? currentWeekStart
        case .year:
            let currentMonthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            return calendar.date(byAdding: .month, value: -11, to: currentMonthStart) ?? currentMonthStart
        }
    }

    private static func dailyTrend(days: Int, messages: [MessageStatRecord], startDate: Date, calendar: Calendar) -> [Int] {
        (0..<days).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDate) else { return 0 }
            return messages.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }.count
        }
    }

    private static func weeklyTrend(weeks: Int, messages: [MessageStatRecord], now: Date, calendar: Calendar) -> [Int] {
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return (0..<weeks).map { index in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: index - weeks + 1, to: currentWeekStart),
                  let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else {
                return 0
            }
            return messages.filter { $0.createdAt >= weekStart && $0.createdAt < weekEnd }.count
        }
    }

    private static func monthlyTrend(messages: [MessageStatRecord], now: Date, calendar: Calendar) -> [Int] {
        let currentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        return (0..<12).reversed().map { offset in
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: currentMonth),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                return 0
            }
            return messages.filter { $0.createdAt >= monthStart && $0.createdAt < monthEnd }.count
        }
    }

    private static func expenseTotal(from notes: [NoteStatRecord]) -> Int {
        let total = notes
            .filter { $0.category == .bill }
            .compactMap(\.expenseAmount)
            .reduce(Decimal.zero, +)
        return Int(NSDecimalNumber(decimal: total).rounding(accordingToBehavior: nil).intValue)
    }

    private static func expenseItems(from notes: [NoteStatRecord]) -> [ExpenseLegendItem] {
        let totalsByCategory = Dictionary(grouping: notes.filter { $0.category == .bill }) { note in
            note.expenseCategory ?? .other
        }
        .mapValues { notes in
            notes.compactMap(\.expenseAmount).reduce(Decimal.zero, +)
        }
        let total = totalsByCategory.values.reduce(Decimal.zero, +)
        let totalValue = NSDecimalNumber(decimal: total).doubleValue

        return ExpenseCategory.allCases.enumerated().map { index, category in
            let amount = NSDecimalNumber(decimal: totalsByCategory[category] ?? .zero).doubleValue
            return ExpenseLegendItem(
                category: category,
                percent: totalValue > 0 ? amount / totalValue * 100 : 0,
                color: category.profileColor,
                sortIndex: index
            )
        }
        .sortedByPercentDescending()
    }

    private static func distributionItems(from notes: [NoteStatRecord]) -> [DistributionLegendItem] {
        let categories: [ThoughtCategory] = [.todo, .qa, .idea, .bill]
        let counts = Dictionary(grouping: notes, by: \.category).mapValues(\.count)
        let total = categories.reduce(0) { $0 + (counts[$1] ?? 0) }

        return categories.enumerated().map { index, category in
            let count = counts[category] ?? 0
            return DistributionLegendItem(
                title: category.rawValue,
                percent: total > 0 ? Double(count) / Double(total) * 100 : 0,
                color: category.noteColor,
                sortIndex: index
            )
        }
        .sortedByPercentDescending()
    }
}

private extension ExpenseCategory {
    var profileColor: Color {
        switch self {
        case .food: .mindGold
        case .transit: .mindTeal
        case .shopping: .mindRose
        case .entertainment: .mindPurple
        case .education: .mindGreen
        case .home: .mindAccent
        case .relationship: .mindOrange
        case .other: .mindGray
        }
    }
}

private struct DistributionLegendItem: Identifiable {
    let title: String
    let percent: Double
    let color: Color
    let sortIndex: Int

    var id: String { title }
    var valueText: String { "\(Int(percent))%" }
}

private struct ProfileAvatar: View {
    @EnvironmentObject private var store: AppStore
    let size: CGFloat

    var body: some View {
        Group {
            if !store.isLoggedIn {
                Image(UserProfile.defaultAvatarName)
                    .resizable()
                    .scaledToFill()
            } else if let avatarImage {
                Image(uiImage: avatarImage)
                    .resizable()
                    .scaledToFill()
            } else if let avatarURL = store.profile.avatarURL,
                      let url = URL(string: avatarURL) {
                CachedRemoteAvatarImage(url: url)
            } else {
                Image(UserProfile.defaultAvatarName)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.07), radius: 16, y: 8)
    }

    private var avatarImage: UIImage? {
        guard let base64 = store.profile.avatarDataBase64,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private struct MetricCard<Content: View>: View {
    let title: String
    let caption: String?
    let content: Content

    init(title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.mindInk)

                Spacer(minLength: 8)

                if let caption {
                    Text(caption)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.mindInk.opacity(0.42))
                        .lineLimit(1)
                }
            }

            content
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.separatorLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 10, y: 5)
    }
}

private struct LineChartView: View {
    let values: [Int]
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let safeValues = values.count > 1 ? values : [0, values.first ?? 0]
            let step = width / CGFloat(safeValues.count - 1)
            let minValue = CGFloat(safeValues.min() ?? 0)
            let maxValue = CGFloat(safeValues.max() ?? 1)
            let valueRange = max(maxValue - minValue, 1)
            let chartPoints = safeValues.enumerated().map { index, value in
                let normalized = (CGFloat(value) - minValue) / valueRange
                let pointHeight = 0.18 + normalized * 0.62
                return CGPoint(x: CGFloat(index) * step, y: height - pointHeight * height)
            }
            let peakIndex = safeValues.indices.max { safeValues[$0] < safeValues[$1] } ?? 0
            let peak = chartPoints[peakIndex]

            ZStack {
                VStack {
                    ForEach(0..<3, id: \.self) { _ in
                        Divider().overlay(Color.separatorLine)
                        Spacer()
                    }
                }

                Path { path in
                    guard let first = chartPoints.first else { return }
                    path.move(to: first)
                    for point in chartPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .trim(from: 0, to: progress)
                .stroke(Color.mindAccent.opacity(0.78), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(Array(chartPoints.enumerated()), id: \.offset) { index, point in
                    if safeValues[index] > 0 {
                        Circle()
                            .fill(Color.cardSurface)
                            .overlay(Circle().stroke(Color.mindAccent.opacity(0.58), lineWidth: 1.8))
                            .frame(width: 9, height: 9)
                            .position(point)
                            .opacity(progress)
                    }
                }

                Path { path in
                    path.move(to: CGPoint(x: peak.x, y: 18))
                    path.addLine(to: CGPoint(x: peak.x, y: height - 8))
                }
                .stroke(Color.mindInk.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .opacity(progress)

                Circle()
                    .fill(Color.cardSurface)
                    .stroke(Color.mindAccent.opacity(0.78), lineWidth: 2.4)
                    .frame(width: 15, height: 15)
                    .position(peak)
                    .opacity(progress)

                Text("\(safeValues[peakIndex]) 次")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.mindInk.opacity(0.52))
                    .position(x: min(max(peak.x, 28), width - 28), y: 12)
                    .opacity(progress)
            }
        }
    }
}

private struct ExpenseLegendItem: Identifiable {
    let category: ExpenseCategory
    let percent: Double
    let color: Color
    let sortIndex: Int

    var id: ExpenseCategory { category }
    var valueText: String { "\(Int(percent))%" }
}

private extension Array where Element == ExpenseLegendItem {
    func sortedByPercentDescending() -> [ExpenseLegendItem] {
        sorted {
            if $0.percent == $1.percent {
                return $0.sortIndex < $1.sortIndex
            }
            return $0.percent > $1.percent
        }
    }
}

private extension Array where Element == DistributionLegendItem {
    func sortedByPercentDescending() -> [DistributionLegendItem] {
        sorted {
            if $0.percent == $1.percent {
                return $0.sortIndex < $1.sortIndex
            }
            return $0.percent > $1.percent
        }
    }
}

private struct ExpenseLegendGrid: View {
    let items: [ExpenseLegendItem]

    private let rowsPerColumn = 4
    private var columns: [[ExpenseLegendItem]] {
        stride(from: 0, to: items.count, by: rowsPerColumn).map { start in
            Array(items[start..<min(start + rowsPerColumn, items.count)])
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: columns.count > 1 ? 12 : 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, columnItems in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(columnItems) { item in
                        ExpenseLegendRow(item: item)
                    }
                }
                .frame(width: columns.count > 1 ? 90 : 126, alignment: .leading)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ExpenseLegendRow: View {
    let item: ExpenseLegendItem

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(item.color)
                .frame(width: 8, height: 8)
            Text(item.category.rawValue)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(item.valueText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.mindInk.opacity(0.72))
        .frame(maxWidth: .infinity, alignment: .leading)
        .minimumScaleFactor(0.9)
    }
}

private struct DonutChartView: View, Animatable {
    let values: [Double]
    let colors: [Color]
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let total = values.reduce(0, +)
            guard total > 0 else { return }
            let clampedProgress = min(max(progress, 0), 1)
            let rect = CGRect(origin: .zero, size: size)
            let radius = min(size.width, size.height) / 2
            var start = Angle.degrees(-90)

            for index in values.indices {
                guard colors.indices.contains(index) else { continue }
                let angle = Angle.degrees(values[index] / total * 360 * Double(clampedProgress))
                var path = Path()
                path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: start, endAngle: start + angle, clockwise: false)
                path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
                path.closeSubpath()
                context.fill(path, with: .color(colors[index]))
                start += angle
            }

            context.fill(Path(ellipseIn: rect.insetBy(dx: 30, dy: 30)), with: .color(.cardSurface))
        }
    }
}

private struct LegendRow: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color.mindInk.opacity(0.72))
    }
}

private struct SettingsPageView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let onOpenNotificationSettings: () -> Void
    @State private var showProfileEditor = false
    @State private var showWelcomePage = false
    @State private var selectedDocument: SettingsDocument?
    @State private var showDeleteAccountConfirmation = false

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 12) {
                        SettingsListGroup {
                            SettingsPageRow(title: "个人资料") {
                                if store.isLoggedIn {
                                    showProfileEditor = true
                                } else {
                                    showWelcomePage = true
                                }
                            }
                            rowDivider
                            SettingsPageRow(title: "通知设置", action: onOpenNotificationSettings)
                            rowDivider
                            SettingsAppearanceToggleRow(isOn: $store.followsSystemAppearance)
                        }

                        SettingsListGroup {
                            SettingsPageRow(title: "隐私政策") {
                                selectedDocument = .privacy
                            }
                            rowDivider
                            SettingsPageRow(title: "用户协议") {
                                selectedDocument = .agreement
                            }
                            rowDivider
                            SettingsPageRow(title: "关于念落") {
                                selectedDocument = .about
                            }
                        }

                        if store.isLoggedIn {
                            SettingsListGroup {
                                SettingsPageRow(title: "退出登录") {
                                    store.logout()
                                    dismiss()
                                }
                                rowDivider
                                SettingsPageRow(
                                    title: store.isDeletingAccount ? "正在注销账号..." : "注销账号",
                                    titleColor: .red,
                                    showsChevron: false
                                ) {
                                    showDeleteAccountConfirmation = true
                                }
                                .disabled(store.isDeletingAccount)
                                .opacity(store.isDeletingAccount ? 0.56 : 1)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .enableNavigationSwipeBack()
        .animateTabBarReturnWhenDisappearing(shouldAnimate: !showProfileEditor && !showWelcomePage && selectedDocument == nil)
        .navigationDestination(isPresented: $showProfileEditor) {
            ProfileEditorView(animateTabBarReturn: false)
        }
        .navigationDestination(isPresented: $showWelcomePage) {
            WelcomeView(presentationContext: .settings)
        }
        .navigationDestination(item: $selectedDocument) { document in
            SettingsDocumentPage(document: document)
        }
        .alert("确认注销账号？", isPresented: $showDeleteAccountConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认注销账号", role: .destructive) {
                Task {
                    if await store.deleteAccount() {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("注销后，你的账号、云端同步数据、提醒推送记录和飞书连接将被删除，当前设备上的念落数据也会清空。此操作无法恢复。")
        }
    }

    private var header: some View {
        ZStack {
            Text("设置")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.mindInk)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.mindInk)
                        .frame(width: 52, height: 52)
                        .background(Color.cardSurface, in: Circle())
                        .shadow(color: .black.opacity(0.035), radius: 10, y: 5)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 72)
        .background(Color.cardSurface)
        .overlay(Divider().opacity(0.55), alignment: .bottom)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 20)
    }
}

private struct SettingsAppearanceToggleRow: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("夜间模式跟随系统设置")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mindInk)

                Text("夜间模式跟随系统设置的模式保持一致")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mindInk.opacity(0.46))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
        .frame(minHeight: 72)
        .padding(.horizontal, 20)
    }
}

private struct SettingsListGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.cardSurface)
    }
}

private struct SettingsPageRow: View {
    let title: String
    var detail: String?
    var titleColor: Color = .mindInk
    var showsChevron = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(titleColor)

                Spacer()

                if let detail {
                    Text(detail)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.mindInk.opacity(0.48))
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.mindInk.opacity(0.18))
                }
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsShareRow: View {
    let title: String
    let url: URL

    var body: some View {
        ShareLink(item: url) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mindInk)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mindInk.opacity(0.18))
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum SettingsDocument: String, Identifiable {
    case privacy = "隐私政策"
    case agreement = "用户协议"
    case about = "关于念落"

    var id: String { rawValue }

    var meta: String {
        switch self {
        case .privacy, .agreement:
            "生效日期：2026年5月25日"
        case .about:
            ""
        }
    }

    var intro: String {
        switch self {
        case .privacy:
            "念落重视你的个人信息和内容安全。本政策说明我们在提供对话收纳、便签整理、云端同步、提醒推送、账单识别、语音输入、个人数据统计和飞书 Bot 连接等功能时，如何处理相关信息。"
        case .agreement:
            "欢迎使用念落。本协议是你与念落之间关于下载、安装、访问和使用本应用、云端服务及相关集成功能所订立的规则。"
        case .about:
            "念落是一款把零散想法、对话、待办、账单和灵感轻轻收纳起来的个人记录工具。"
        }
    }

    var sections: [LegalDocumentSection] {
        switch self {
        case .privacy:
            [
                LegalDocumentSection(
                    title: "我们处理的信息",
                    paragraphs: [
                        "• 账号与个人资料：你设置的昵称、用户 ID、头像等基础资料。",
                        "• 你主动输入或同步的内容：对话文本、飞书单聊消息、便签标题与正文、分类、提醒时间、账单金额和账单类型。",
                        "• 同步与提醒信息：记录的创建、更新时间、删除时间、回收站状态、云端同步状态、设备推送 token、推送环境和提醒发送状态。",
                        "• 飞书连接信息：当你主动配对飞书 Bot 时，我们会处理你提交的 App ID、App Secret、Verification Token、Encrypt Key、飞书 open_id、事件 ID 和绑定状态。敏感配置不会以明文写入聊天记录。",
                        "• 语音输入信息：当你使用语音输入时，应用会请求麦克风和语音识别权限，并接收系统语音识别返回的文字结果。",
                        "• 设备与权限状态：通知权限、麦克风权限、语音识别权限、系统外观设置等，用于判断相关功能是否可用。"
                    ]
                ),
                LegalDocumentSection(
                    title: "处理目的",
                    paragraphs: [
                        "我们处理上述信息，是为了完成你主动发起的记录、归类、提醒、编辑、删除、恢复、搜索、跨设备同步和数据展示等操作。",
                        "对话内容会用于生成回复、识别待办/问答/灵感/账单类型、创建或更新便签、生成提醒通知文案，以及在必要范围内提供最近上下文。",
                        "账单金额和类型用于账单记录、历史筛选和个人数据统计；提醒时间用于本地通知和云端远程推送；飞书连接信息用于校验回调、绑定你的 Bot 单聊并同步飞书消息产生的记录。"
                    ]
                ),
                LegalDocumentSection(
                    title: "存储与同步",
                    paragraphs: [
                        "念落会在你的设备本地保存必要数据；登录后，会将个人资料、便签、对话记录、删除标记、提醒状态和部分设置同步到云端，以支持多端安全的增量同步。",
                        "当你删除便签或对话时，系统可能会保留删除标记一段时间，用于避免已删除内容在其他设备重新出现。回收站、永久删除和云端同步完成后，相关内容会按当前产品规则处理。",
                        "飞书 App Secret、Verification Token 和 Encrypt Key 会发送到服务端并加密保存，用于验证飞书回调和发送 Bot 回复；应用内聊天记录只显示已隐藏的占位文案。"
                    ]
                ),
                LegalDocumentSection(
                    title: "系统权限",
                    paragraphs: [
                        "麦克风和语音识别权限用于语音输入；通知权限用于本地提醒和接收云端远程提醒推送。你可以在系统设置中随时关闭这些权限，关闭后对应功能可能无法使用。",
                        "语音识别由系统能力提供，具体处理方式会受到操作系统及其语音识别服务规则约束。念落使用识别后的文字来完成你的记录请求。"
                    ]
                ),
                LegalDocumentSection(
                    title: "云端服务与第三方",
                    paragraphs: [
                        "为实现账号登录、云端同步、AI 分析、远程推送和飞书 Bot 连接，相关信息可能会经过我们部署的服务端、数据库服务、AI 服务、Apple 推送服务和飞书开放平台处理。",
                        "当你通过飞书 Bot 与念落交流时，消息会先经过飞书平台，再由念落服务端处理并同步到你的账号。飞书侧的信息处理同时受飞书平台规则约束。",
                        "除法律法规要求、获得你的明确授权，或为实现你主动请求的功能外，我们不会主动向第三方出售、出租或公开你的个人信息和便签内容。当前版本未接入广告投放、用户画像或商业化追踪 SDK。"
                    ]
                ),
                LegalDocumentSection(
                    title: "安全保护",
                    paragraphs: [
                        "我们会采取合理的技术措施保护你的数据，例如使用登录态校验、行级访问控制、敏感配置加密保存和服务端密钥管理。",
                        "互联网服务无法保证绝对安全。请妥善保管你的账号、设备、飞书应用凭证和系统权限，不要向不可信对象泄露敏感配置。"
                    ]
                ),
                LegalDocumentSection(
                    title: "你的权利",
                    paragraphs: [
                        "你可以在应用内查看、编辑、删除便签和对话，移动到回收站或永久删除记录；你也可以修改个人资料、退出登录或关闭系统权限。",
                        "你可以在设置页发起注销账号。注销完成后，念落会删除你的账号、云端同步数据、提醒推送记录和飞书连接信息，并清空当前设备上的本地数据。",
                        "如果你希望访问、更正、删除更多个人信息，撤销飞书连接，或对本政策有疑问，可以通过应用商店展示的开发者联系方式与我们联系。"
                    ]
                ),
                LegalDocumentSection(
                    title: "未成年人保护",
                    paragraphs: [
                        "如果你是不满 14 周岁的未成年人，应在监护人同意和指导下使用念落。监护人发现未成年人信息被不当处理的，可以联系我们处理。"
                    ]
                ),
                LegalDocumentSection(
                    title: "政策更新",
                    paragraphs: [
                        "当功能、信息处理范围、第三方服务或法律要求发生变化时，我们可能更新本政策，并通过应用内页面或其他合理方式提示你查看。"
                    ]
                )
            ]
        case .agreement:
            [
                LegalDocumentSection(
                    title: "服务内容",
                    paragraphs: [
                        "念落提供对话记录、便签整理、分类收纳、待办提醒、账单识别、个人数据展示、语音输入、云端同步、远程提醒推送和飞书 Bot 连接等工具能力。",
                        "部分功能依赖账号登录、网络连接、系统权限或第三方服务。例如，语音输入需要麦克风和语音识别权限，提醒推送需要通知权限，飞书连接需要你提供企业自建应用的必要配置。"
                    ]
                ),
                LegalDocumentSection(
                    title: "账号与资料",
                    paragraphs: [
                        "你应保证填写的昵称、用户 ID 等资料真实、合法，不侵犯他人权利，也不得冒充他人或使用误导性信息。",
                        "你可以在应用内设置页注销账号。注销账号会删除账号及相关云端数据，并清空当前设备上的本地数据；注销完成后无法恢复。",
                        "你应妥善管理自己的设备、账号、登录状态、飞书应用凭证和数据。因你主动删除、卸载应用、泄露凭证、关闭权限或设备异常导致的数据丢失、同步失败或功能不可用，念落可能无法恢复。"
                    ]
                ),
                LegalDocumentSection(
                    title: "用户内容",
                    paragraphs: [
                        "你对自己输入、保存、编辑和删除的内容负责。请勿利用念落记录、传播违法违规、侵害他人权益或危害公共利益的内容。",
                        "你保留对自己内容依法享有的权利。为了提供分类、提醒、展示和统计等功能，念落会在必要范围内处理这些内容。"
                    ]
                ),
                LegalDocumentSection(
                    title: "AI、账单、提醒与语音功能",
                    paragraphs: [
                        "AI 分析、回复、标题生成、分类、账单识别和个人数据统计仅作为个人记录辅助，可能存在遗漏或误判，不构成财务、税务、投资、医疗、法律或其他专业建议。",
                        "提醒功能受系统通知权限、勿扰模式、设备状态、网络、云端任务和 Apple 推送服务等影响，可能存在延迟或未送达。请勿将其作为处理重要事务的唯一依据。",
                        "语音识别可能因环境噪声、口音、网络或系统能力产生误差，请在保存前自行核对重要内容。"
                    ]
                ),
                LegalDocumentSection(
                    title: "飞书 Bot 连接",
                    paragraphs: [
                        "飞书 Bot 连接仅支持你主动配置并完成绑定的单聊场景。你应确保自己有权创建和管理对应的企业自建应用，并遵守飞书开放平台和所在组织的管理要求。",
                        "你通过飞书发送给 Bot 的内容会被用于生成回复、创建或更新记录，并同步到念落账号。请勿向 Bot 发送你无权处理、依法不得处理或不希望同步到念落的数据。",
                        "如果你重置、删除或泄露飞书应用凭证，可能导致连接失败、消息无法同步或产生安全风险。发现异常时，应及时调整飞书应用配置并联系我们处理。"
                    ]
                ),
                LegalDocumentSection(
                    title: "禁止行为",
                    paragraphs: [
                        "你不得通过逆向工程、恶意攻击、自动化滥用、绕过权限限制等方式破坏应用正常运行。",
                        "你不得使用念落从事违法活动，或上传、保存、传播侵犯他人隐私、知识产权、名誉权等合法权益的内容。",
                        "你不得利用飞书连接、云同步、提醒推送或 AI 能力发送骚扰信息、垃圾信息、欺诈内容，或进行超出个人记录目的的自动化滥用。"
                    ]
                ),
                LegalDocumentSection(
                    title: "服务变更与中止",
                    paragraphs: [
                        "我们可能根据产品规划、系统要求、第三方服务变化、安全原因或成本因素调整、暂停或终止部分功能，并尽量以合理方式告知你。",
                        "如果你违反本协议或法律法规，我们有权限制相关功能或采取必要措施。"
                    ]
                ),
                LegalDocumentSection(
                    title: "责任限制",
                    paragraphs: [
                        "念落会尽力保持服务稳定和数据安全，但不承诺服务永不中断、完全无错误、同步绝不冲突、提醒必定送达或识别结果绝对准确。",
                        "在法律允许范围内，因不可抗力、系统故障、第三方服务异常、网络异常、用户误操作、凭证泄露等原因造成的损失，我们不承担超出法律规定的责任。"
                    ]
                ),
                LegalDocumentSection(
                    title: "协议更新",
                    paragraphs: [
                        "我们可能根据功能变化或法律要求更新本协议。更新后继续使用念落，即表示你已了解并接受更新内容。"
                    ]
                )
            ]
        case .about:
            []
        }
    }
}

private struct LegalDocumentSection: Identifiable {
    let title: String
    let paragraphs: [String]

    var id: String { title }
}

private struct SettingsDocumentPage: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let document: SettingsDocument
    @State private var isOpeningReviewPage = false
    private static let shareURL = URL(string: "https://apps.apple.com/cn/app/%E5%BF%B5%E8%90%BD%E7%AC%94%E8%AE%B0/id6772984960")!

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    content
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .enableNavigationSwipeBack()
    }

    @ViewBuilder
    private var content: some View {
        switch document {
        case .privacy, .agreement:
            SettingsDocumentBlock {
                VStack(alignment: .leading, spacing: 16) {
                    Text(document.meta)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.mindInk.opacity(0.46))

                    Text(document.intro)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.mindInk.opacity(0.78))
                        .lineSpacing(4)

                    ForEach(document.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.mindInk)

                            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(Color.mindInk.opacity(0.70))
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        case .about:
            aboutContent
        }
    }

    private var aboutContent: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                BrandMark(size: 86)
                Text("念落笔记")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.mindInk)
                Text("接住你每一个想法")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.mindInk.opacity(0.52))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 10)

            SettingsListGroup {
                SettingsInfoRow(title: "版本号", value: "1.0.0")
                Divider().padding(.leading, 20)
                SettingsInfoRow(title: "开发者", value: "Ryan Xu")
                Divider().padding(.leading, 20)
                SettingsInfoRow(title: "联系方式", value: "xxx@xxxxxxx.tw")
                Divider().padding(.leading, 20)
                SettingsPageRow(title: "去评分", action: openReviewPage)
                Divider().padding(.leading, 20)
                SettingsShareRow(title: "分享给朋友", url: Self.shareURL)
            }
        }
    }

    private func openReviewPage() {
        guard !isOpeningReviewPage else { return }
        isOpeningReviewPage = true

        Task {
            do {
                let config = try await RemoteConfigService.shared.fetchAppConfig()
                await MainActor.run {
                    isOpeningReviewPage = false
                    guard let reviewURL = config.reviewURL else {
                        store.presentToast("评分入口上架后开放")
                        return
                    }
                    openURL(reviewURL)
                }
            } catch {
                await MainActor.run {
                    isOpeningReviewPage = false
                    store.presentToast("评分入口暂时不可用")
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Text(document.rawValue)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.mindInk)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.mindInk)
                        .frame(width: 52, height: 52)
                        .background(Color.cardSurface, in: Circle())
                        .shadow(color: .black.opacity(0.035), radius: 10, y: 5)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 72)
        .background(Color.cardSurface)
        .overlay(Divider().opacity(0.55), alignment: .bottom)
    }
}

private struct SettingsDocumentBlock<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(Color.cardSurface)
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.mindInk)

            Spacer()

            Text(value)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.mindInk.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 20)
    }
}

private struct ProfileEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let animateTabBarReturn: Bool
    @State private var nickname: String
    @State private var userID: String
    @State private var avatarDataBase64: String?
    @State private var avatarURL: String?
    @State private var shouldRemoveAvatar = false
    @State private var showAvatarMenu = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var cropSourceImage: UIImage?
    @State private var showAvatarCropper = false
    @State private var isCropperPending = false
    @State private var isLoadingAvatar = false

    init(animateTabBarReturn: Bool = false) {
        self.animateTabBarReturn = animateTabBarReturn
        _nickname = State(initialValue: "")
        _userID = State(initialValue: "")
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 12) {
                        SettingsListGroup {
                            HStack(spacing: 12) {
                                Text("头像")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.mindInk)

                                Spacer()

                                Button {
                                    showAvatarMenu = true
                                } label: {
                                    AvatarPreviewView(
                                        avatarDataBase64: avatarDataBase64,
                                        avatarURL: avatarURL,
                                        size: 48
                                    )
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "camera.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 20, height: 20)
                                            .background(Color.mindInk.opacity(0.78), in: Circle())
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(minHeight: 64)
                            .padding(.horizontal, 20)
                        }

                        SettingsListGroup {
                            profileFieldRow(title: "昵称", text: $nickname, placeholder: "1-16 个字符")
                            rowDivider
                            profileFieldRow(title: "用户 ID", text: $userID, placeholder: "3-20 位字母或数字")
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Text("用户ID支持3-20位字母和数字，不支持纯数字")
                            .font(.footnote)
                            .foregroundStyle(Color.mindInk.opacity(0.48))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 2)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }

            if isLoadingAvatar {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                ProgressView("图片处理中")
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .enableNavigationSwipeBack()
        .animateTabBarReturnWhenDisappearing(shouldAnimate: shouldAnimateTabBarReturn)
        .onAppear {
            nickname = store.profile.nickname
            userID = store.profile.userID
            avatarDataBase64 = nil
            avatarURL = store.profile.avatarURL
            shouldRemoveAvatar = false
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .onChange(of: showPhotoPicker) { _, isPresented in
            guard !isPresented, isCropperPending, cropSourceImage != nil else { return }
            presentAvatarCropperAfterPickerDismissal()
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            showPhotoPicker = false
            Task {
                await loadSelectedAvatar(from: item)
            }
        }
        .fullScreenCover(isPresented: $showAvatarMenu) {
            AvatarActionView(
                avatarDataBase64: avatarDataBase64,
                avatarURL: avatarURL,
                onUpload: {
                    showAvatarMenu = false
                    presentPhotoPickerAfterAvatarMenuDismissal()
                },
                onRestoreDefault: {
                    avatarDataBase64 = nil
                    avatarURL = nil
                    shouldRemoveAvatar = true
                    showAvatarMenu = false
                },
                onClose: {
                    showAvatarMenu = false
                }
            )
        }
        .fullScreenCover(isPresented: $showAvatarCropper) {
            if let cropSourceImage {
                AvatarCropperView(image: cropSourceImage) { data in
                    avatarDataBase64 = data.base64EncodedString()
                    avatarURL = nil
                    shouldRemoveAvatar = false
                    showAvatarCropper = false
                    selectedPhotoItem = nil
                    isCropperPending = false
                } onCancel: {
                    showAvatarCropper = false
                    selectedPhotoItem = nil
                    isCropperPending = false
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("个人资料")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.mindInk)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.mindInk)
                        .frame(width: 52, height: 52)
                        .background(Color.cardSurface, in: Circle())
                        .shadow(color: .black.opacity(0.035), radius: 10, y: 5)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(store.isSavingProfile ? "保存中" : "保存") {
                    Task {
                        if await store.updateProfile(
                            nickname: nickname,
                            userID: userID,
                            avatarDataBase64: avatarDataBase64,
                            shouldRemoveAvatar: shouldRemoveAvatar
                        ) {
                            dismiss()
                        }
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSaveDisabled ? Color.mindInk.opacity(0.28) : Color.mindAccent)
                .disabled(isSaveDisabled || store.isSavingProfile)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 72)
        .background(Color.cardSurface)
        .overlay(Divider().opacity(0.55), alignment: .bottom)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 20)
    }

    private var isSaveDisabled: Bool {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func profileFieldRow(title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.mindInk)

            TextField(placeholder, text: text)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.mindInk)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 20)
    }

    private func loadSelectedAvatar(from item: PhotosPickerItem) async {
        await MainActor.run {
            isLoadingAvatar = true
        }
        defer {
            Task { @MainActor in
                isLoadingAvatar = false
            }
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage.downsampledAvatarSource(from: data) else {
                await MainActor.run {
                    selectedPhotoItem = nil
                    isCropperPending = false
                    store.presentToast("无法读取这张图片")
                }
                return
            }

            await MainActor.run {
                cropSourceImage = image
                isCropperPending = true
                if !showPhotoPicker {
                    presentAvatarCropperAfterPickerDismissal()
                }
            }
        } catch {
            await MainActor.run {
                selectedPhotoItem = nil
                isCropperPending = false
                store.presentToast("读取图片失败")
            }
        }
    }

    private func presentAvatarCropperAfterPickerDismissal() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard isCropperPending, cropSourceImage != nil, !showPhotoPicker else { return }
            showAvatarCropper = true
        }
    }

    private func presentPhotoPickerAfterAvatarMenuDismissal() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            showPhotoPicker = true
        }
    }

    private var shouldAnimateTabBarReturn: Bool {
        animateTabBarReturn && !showAvatarMenu && !showPhotoPicker && !showAvatarCropper
    }
}

private struct AvatarPreviewView: View {
    let avatarDataBase64: String?
    let avatarURL: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let avatarImage {
                Image(uiImage: avatarImage)
                    .resizable()
                    .scaledToFill()
            } else if let avatarURL, let url = URL(string: avatarURL) {
                CachedRemoteAvatarImage(url: url)
            } else {
                Image(UserProfile.defaultAvatarName)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.07), radius: 16, y: 8)
    }

    private var avatarImage: UIImage? {
        guard let avatarDataBase64,
              let data = Data(base64Encoded: avatarDataBase64) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private struct CachedRemoteAvatarImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.cardSurface
            }
        }
        .task(id: url.absoluteString) {
            await loadImageIfNeeded()
        }
    }

    private var displayImage: UIImage? {
        image ?? AvatarImageCache.shared.image(for: url)
    }

    private func loadImageIfNeeded() async {
        if let cachedImage = AvatarImageCache.shared.image(for: url) {
            await MainActor.run {
                image = cachedImage
            }
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, let loadedImage = UIImage(data: data) else { return }
            AvatarImageCache.shared.store(loadedImage, for: url)
            await MainActor.run {
                image = loadedImage
            }
        } catch {
            // Keep the neutral avatar surface instead of flashing the default avatar.
        }
    }
}

private final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {}

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

private struct AvatarActionView: View {
    let avatarDataBase64: String?
    let avatarURL: String?
    let onUpload: () -> Void
    let onRestoreDefault: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 52)

                Spacer(minLength: 30)

                AvatarPreviewView(avatarDataBase64: avatarDataBase64, avatarURL: avatarURL, size: 320)
                    .shadow(color: .white.opacity(0.04), radius: 24, y: 8)

                Spacer(minLength: 72)

                VStack(spacing: 0) {
                    AvatarActionRow(title: "上传新头像", systemName: "photo") {
                        onUpload()
                    }

                    Divider()
                        .overlay(Color.white.opacity(0.06))
                        .padding(.leading, 18)

                    AvatarActionRow(title: "恢复默认头像", systemName: "arrow.counterclockwise.circle") {
                        onRestoreDefault()
                    }
                }
                .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }
                .padding(.horizontal, 37)
                .padding(.bottom, 62)
            }
        }
    }
}

private struct AvatarActionRow: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))

                Spacer()

                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 28, height: 28)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AvatarCropperView: View {
    let image: UIImage
    let onSave: (Data) -> Void
    let onCancel: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let cropSize: CGFloat = 300
    private let outputSize: CGFloat = 512

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text("拖动图片调整位置，双指或下方滑块缩放")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.mindInk.opacity(0.54))
                    .padding(.top, 14)

                ZStack {
                    Color.black.opacity(0.88)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cropSize, height: cropSize)
                        .scaleEffect(scale)
                        .offset(offset)
                        .clipShape(Circle())

                    Circle()
                        .stroke(.white.opacity(0.92), lineWidth: 2)
                        .frame(width: cropSize, height: cropSize)
                }
                .frame(width: cropSize, height: cropSize)
                .clipShape(Circle())
                .contentShape(Circle())
                .gesture(dragGesture)
                .simultaneousGesture(magnificationGesture)

                Slider(value: $scale, in: 1...4)
                    .tint(.mindAccent)
                    .padding(.horizontal, 28)

                Spacer()
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("裁切头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let data = image.avatarJPEGData(
                            scale: scale,
                            offset: offset,
                            cropSize: cropSize,
                            outputSize: outputSize
                        ) {
                            onSave(data)
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
            }
    }
}

private extension UIImage {
    static func downsampledAvatarSource(from data: Data, maxPixelSize: CGFloat = 1600) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: image)
    }

    func avatarJPEGData(scale: CGFloat, offset: CGSize, cropSize: CGFloat, outputSize: CGFloat) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))
        let outputImage = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: outputSize, height: outputSize))

            let baseRatio = max(outputSize / size.width, outputSize / size.height)
            let drawWidth = size.width * baseRatio * scale
            let drawHeight = size.height * baseRatio * scale
            let offsetRatio = outputSize / cropSize
            let drawRect = CGRect(
                x: (outputSize - drawWidth) / 2 + offset.width * offsetRatio,
                y: (outputSize - drawHeight) / 2 + offset.height * offsetRatio,
                width: drawWidth,
                height: drawHeight
            )
            draw(in: drawRect)
        }
        return outputImage.jpegData(compressionQuality: 0.82)
    }
}

private extension Color {
    static let mindGold = Color(red: 0.86, green: 0.69, blue: 0.30)
    static let mindRose = Color(red: 0.84, green: 0.45, blue: 0.49)
    static let mindTeal = Color(red: 0.44, green: 0.67, blue: 0.64)
    static let mindGray = Color(red: 0.70, green: 0.73, blue: 0.76)
    static let mindPurple = Color(red: 0.53, green: 0.50, blue: 0.76)
    static let mindGreen = Color(red: 0.48, green: 0.65, blue: 0.45)
    static let mindOrange = Color(red: 0.84, green: 0.56, blue: 0.34)
}
