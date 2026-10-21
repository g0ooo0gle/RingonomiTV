import SwiftUI
import RingonomiCore

/// 一つのフォーカス領域で移動を管理し、短い番組でもフォーカスを失わない。
struct GuideGridView: View {
    let layout: GuideGridLayout
    let jumpRevision: Int
    let returnFocusRevision: Int
    let onSelect: (GuideProgram, GuideChannel) -> Void
    let onLeaveGrid: () -> Void
    @State private var position = GuideGridFocus()
    @State private var scrollX: CGFloat = 0
    @State private var scrollY: CGFloat = 0
    @State private var initialized = false
    @FocusState private var hasFocus: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorStyle) private var appColorStyle
    private let axisWidth: CGFloat = 72
    private let headerHeight: CGFloat = 64
    private let pointsPerMinute: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: max(1, geometry.size.width - axisWidth),
                                  height: max(1, geometry.size.height - headerHeight))
            let columnWidth = max(210, min(280, viewport.width / 6.5))
            let palette = appColorStyle.palette(for: colorScheme)
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Canvas { context, size in
                    draw(
                        context: context,
                        size: size,
                        columnWidth: columnWidth,
                        now: timeline.date,
                        palette: palette
                    )
                }
            }
            .background(palette.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .focusable()
            .focused($hasFocus)
            .focusEffectDisabled()
            .onAppear {
                if !initialized {
                    initialized = true
                    jumpToNow(viewport: viewport, columnWidth: columnWidth)
                } else { hasFocus = true }
            }
            .onChange(of: jumpRevision) { _, _ in jumpToNow(viewport: viewport, columnWidth: columnWidth) }
            .onChange(of: returnFocusRevision) { _, _ in
                followFocus(viewport: viewport, columnWidth: columnWidth)
                hasFocus = true
#if DEBUG
                print("RingonomiGuideReturn: column=\(position.column) minute=\(position.minute)")
#endif
            }
            .onChange(of: hasFocus) { _, value in
                if value { followFocus(viewport: viewport, columnWidth: columnWidth) }
            }
            .onMoveCommand { direction in
                let movement: GuideGridDirection
                switch direction {
                case .left: movement = .left
                case .right: movement = .right
                case .up: movement = .up
                case .down: movement = .down
                @unknown default: return
                }
                let next = layout.move(position, direction: movement)
                if direction == .up, position.minute <= 0 {
                    hasFocus = false
                    onLeaveGrid()
                    return
                }
                position = next
                followFocus(viewport: viewport, columnWidth: columnWidth)
            }
            .onTapGesture {
                guard layout.columns.indices.contains(position.column),
                      let entry = layout.focusedEntry(position) else { return }
#if DEBUG
                print("RingonomiGuideSelect: column=\(position.column) minute=\(position.minute)")
#endif
                hasFocus = false
                onSelect(entry.program, layout.columns[position.column].channel)
            }
            .onExitCommand { hasFocus = false; onLeaveGrid() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("上下で番組、左右でチャンネルを選び、決定で詳細を開きます。")
            .accessibilityIdentifier("guide.grid")
        }
    }
    private var accessibilityLabel: String {
        guard layout.columns.indices.contains(position.column), let entry = layout.focusedEntry(position) else {
            return "番組情報なし"
        }
        let channel = layout.columns[position.column].channel
        return "\(channelTitle(channel))、\(programTitle(entry.program))"
    }
    private func channelTitle(_ channel: GuideChannel) -> String {
        for candidate in [channel.name, channel.displayChannelId] {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return "チャンネル"
    }
    private func programTitle(_ program: GuideProgram) -> String {
        let title = program.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "番組情報なし" : title
    }
    private var accessibilityValue: String {
        guard layout.columns.indices.contains(position.column), let entry = layout.focusedEntry(position) else {
            return "放送時刻なし"
        }
        guard let start = accessibilityDate(entry.program.startDate),
              let end = accessibilityDate(entry.program.endDate) else {
            return "放送時刻不明"
        }
        return "放送時刻 \(start)〜\(end)"
    }
    private func accessibilityDate(_ date: Date?) -> String? {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite,
              date >= .distantPast, date <= .distantFuture else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "M月d日 HH:mm"
        let value = formatter.string(from: date)
        return value.isEmpty ? nil : value
    }
    private func jumpToNow(viewport: CGSize, columnWidth: CGFloat) {
        let minute = min(1439, max(0, Date().timeIntervalSince(layout.baseDate) / 60))
        position = GuideGridFocus(column: min(position.column, max(0, layout.columns.count - 1)), minute: minute)
        scrollY = max(0, CGFloat(minute) * pointsPerMinute - 70)
        followFocus(viewport: viewport, columnWidth: columnWidth)
        hasFocus = true
    }
    private func followFocus(viewport: CGSize, columnWidth: CGFloat) {
        let left = CGFloat(position.column) * columnWidth
        if left < scrollX { scrollX = left }
        if left + columnWidth > scrollX + viewport.width { scrollX = left + columnWidth - viewport.width }
        scrollX = min(max(0, CGFloat(layout.columns.count) * columnWidth - viewport.width), max(0, scrollX))
        let entry = layout.focusedEntry(position)
        let top = CGFloat(entry?.startMinute ?? position.minute) * pointsPerMinute
        let length = CGFloat((entry?.endMinute ?? (position.minute + 30)) - (entry?.startMinute ?? position.minute)) * pointsPerMinute
        let bottom = top + min(max(140, length), viewport.height * 0.75)
        if top < scrollY { scrollY = top }
        if bottom > scrollY + viewport.height { scrollY = bottom - viewport.height }
        scrollY = min(max(0, 1440 * pointsPerMinute - viewport.height), max(0, scrollY))
    }
    private func draw(
        context: GraphicsContext,
        size: CGSize,
        columnWidth: CGFloat,
        now: Date,
        palette: AppColorPalette
    ) {
        let body = CGRect(x: axisWidth, y: headerHeight, width: max(0, size.width - axisWidth), height: max(0, size.height - headerHeight))
        let selectedEntry = layout.focusedEntry(position)
        var grid = context
        grid.clip(to: Path(body))
        for hour in 0...24 {
            let y = headerHeight + CGFloat(hour * 60) * pointsPerMinute - scrollY
            guard y >= headerHeight, y <= size.height else { continue }
            var line = Path(); line.move(to: CGPoint(x: axisWidth, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
            grid.stroke(line, with: .color(palette.gridLine), lineWidth: 1)
        }
        for (index, column) in layout.columns.enumerated() {
            let x = axisWidth + CGFloat(index) * columnWidth - scrollX
            guard x + columnWidth >= axisWidth, x <= size.width else { continue }
            for entry in column.entries {
                let rect = cellRect(entry, column: index, columnWidth: columnWidth)
                guard rect.maxY >= headerHeight, rect.minY <= size.height else { continue }
                let isSelected = index == position.column && entry.id == selectedEntry?.id
                // The expanded selection draws its text below. Keep the
                // original time slot's background without a second title.
                drawEntry(entry, in: rect, context: grid, selected: false,
                          showsText: !isSelected, now: now, palette: palette)
            }
        }
        let minute = now.timeIntervalSince(layout.baseDate) / 60
        let nowY = headerHeight + CGFloat(minute) * pointsPerMinute - scrollY
        if minute >= 0, minute <= 1440, nowY >= headerHeight, nowY <= size.height {
            var line = Path(); line.move(to: CGPoint(x: axisWidth, y: nowY)); line.addLine(to: CGPoint(x: size.width, y: nowY))
            grid.stroke(line, with: .color(palette.currentTime), lineWidth: 2)
        }
        if layout.columns.indices.contains(position.column) {
            if let entry = selectedEntry {
                var rect = cellRect(entry, column: position.column, columnWidth: columnWidth)
                rect.size.height = max(140, min(rect.height, body.height * 0.8))
                rect.origin.y = min(max(headerHeight + 3, rect.minY), max(headerHeight + 3, size.height - rect.height - 3))
                drawEntry(
                    entry,
                    in: rect.insetBy(dx: 2, dy: 1),
                    context: grid,
                    selected: true,
                    now: now,
                    palette: palette
                )
            } else {
                let rect = CGRect(x: axisWidth + CGFloat(position.column) * columnWidth - scrollX + 2,
                                  y: headerHeight + CGFloat(position.minute) * pointsPerMinute - scrollY,
                                  width: columnWidth - 4, height: 100)
                label(
                    "番組情報なし",
                    in: rect.insetBy(dx: 12, dy: 10),
                    context: grid,
                    font: .system(size: 20),
                    color: palette.primaryText
                )
                grid.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(palette.accent), lineWidth: 3)
            }
        }
        // 見出しはスクロール後に重ね、番組の下に隠れないようにする。
        context.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: headerHeight)),
            with: .color(palette.surface)
        )
        context.fill(
            Path(CGRect(x: 0, y: headerHeight, width: axisWidth, height: max(0, size.height - headerHeight))),
            with: .color(palette.surface)
        )
        var headers = context
        headers.clip(to: Path(CGRect(x: axisWidth, y: 0, width: max(0, size.width - axisWidth), height: headerHeight)))
        for (index, column) in layout.columns.enumerated() {
            let x = axisWidth + CGFloat(index) * columnWidth - scrollX
            guard x + columnWidth >= axisWidth, x <= size.width else { continue }
            label(channelTitle(column.channel), in: CGRect(x: x + 10, y: 8, width: columnWidth - 20, height: headerHeight - 12),
                  context: headers, font: .system(size: 20, weight: .semibold), color: palette.primaryText)
        }
        label(
            "時刻",
            in: CGRect(x: 10, y: 18, width: axisWidth - 12, height: 30),
            context: context,
            font: .system(size: 18),
            color: palette.primaryText
        )
        for hour in 0...24 {
            let y = headerHeight + CGFloat(hour * 60) * pointsPerMinute - scrollY
            guard y >= headerHeight, y < size.height - 18 else { continue }
            label("\((hour + 4) % 24)時", in: CGRect(x: 10, y: y + 4, width: axisWidth - 12, height: 30),
                  context: context, font: .system(size: 20, weight: .semibold), color: palette.primaryText)
        }
    }
    private func cellRect(_ entry: GuideGridEntry, column: Int, columnWidth: CGFloat) -> CGRect {
        CGRect(x: axisWidth + CGFloat(column) * columnWidth - scrollX + 1,
               y: headerHeight + CGFloat(entry.startMinute) * pointsPerMinute - scrollY + 1,
               width: columnWidth - 2, height: max(1, CGFloat(entry.endMinute - entry.startMinute) * pointsPerMinute - 2))
    }
    private func drawEntry(
        _ entry: GuideGridEntry,
        in rect: CGRect,
        context: GraphicsContext,
        selected: Bool,
        showsText: Bool = true,
        now: Date,
        palette: AppColorPalette
    ) {
        let color = palette.genreColor(for: entry.program.genres.first?.major ?? "")
        let past = (entry.program.endDate ?? .distantFuture) <= now
        let background = selected ? (hasFocus ? palette.selection : palette.inactiveSelection) : color.opacity(past ? 0.10 : 0.24)
        let shape = Path(roundedRect: rect, cornerRadius: 5)
        if selected {
            // Inactive selection colors can be translucent. An opaque base
            // prevents neighboring titles from showing through the overlay.
            context.fill(shape, with: .color(palette.background))
        }
        context.fill(shape, with: .color(background))
        context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height)), with: .color(color))
        if showsText {
            var cell = context
            cell.clip(to: Path(rect.insetBy(dx: 6, dy: 3)))
            let time = clockText(for: entry.program.startDate)
            label(time, in: CGRect(x: rect.minX + 12, y: rect.minY + 7, width: rect.width - 22, height: 22),
                  context: cell, font: .system(size: 16), color: palette.secondaryText)
            label(programTitle(entry.program), in: CGRect(x: rect.minX + 12, y: rect.minY + 30, width: rect.width - 22, height: max(0, rect.height - 38)),
                  context: cell,
                  font: .system(size: selected ? 23 : 21, weight: selected ? .bold : .medium),
                  color: palette.primaryText.opacity(past && !selected ? 0.55 : 1))
        }
        if entry.program.reservation?.id != nil {
            context.stroke(Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 5),
                           with: .color(palette.reservation), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        if selected {
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 6),
                with: .color(hasFocus ? palette.accent : palette.selectionOutline),
                lineWidth: 4
            )
        }
    }
    private func label(_ text: String, in rect: CGRect, context: GraphicsContext, font: Font, color: Color) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.draw(context.resolve(Text(text).font(font).foregroundColor(color)), in: rect)
    }

    private func clockText(for date: Date?) -> String {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite,
              date >= .distantPast, date <= .distantFuture else { return "--:--" }
        let rawMinute = date.timeIntervalSince(layout.baseDate) / 60
        guard rawMinute.isFinite else { return "--:--" }

        // Truncate before reducing so this preserves the old Int(rawMinute)
        // behavior without converting an abnormal Double directly to Int.
        let truncated = rawMinute.rounded(.towardZero)
        let remainder = truncated.truncatingRemainder(dividingBy: 1440)
        guard remainder.isFinite else { return "--:--" }
        let shifted = (remainder + 240).truncatingRemainder(dividingBy: 1440)
        let normalized = shifted >= 0 ? shifted : shifted + 1440
        guard normalized.isFinite, normalized >= 0, normalized < 1440 else { return "--:--" }
        let minute = Int(normalized)
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
