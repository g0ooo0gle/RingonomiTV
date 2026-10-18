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
    private let axisWidth: CGFloat = 72
    private let headerHeight: CGFloat = 64
    private let pointsPerMinute: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: max(1, geometry.size.width - axisWidth),
                                  height: max(1, geometry.size.height - headerHeight))
            let columnWidth = max(210, min(280, viewport.width / 6.5))
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Canvas { context, size in
                    draw(context: context, size: size, columnWidth: columnWidth, now: timeline.date)
                }
            }
            .background(Color(white: 0.075))
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
                onSelect(entry.program, layout.columns[position.column].channel)
            }
            .onExitCommand { hasFocus = false; onLeaveGrid() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("上下で番組、左右でチャンネルを選び、決定で詳細を開きます。")
        }
    }
    private var accessibilityLabel: String {
        guard layout.columns.indices.contains(position.column), let entry = layout.focusedEntry(position) else {
            return "番組情報なし"
        }
        return layout.columns[position.column].channel.name + "、" + entry.program.title + "、" + entry.program.description
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
    private func draw(context: GraphicsContext, size: CGSize, columnWidth: CGFloat, now: Date) {
        let body = CGRect(x: axisWidth, y: headerHeight, width: max(0, size.width - axisWidth), height: max(0, size.height - headerHeight))
        var grid = context
        grid.clip(to: Path(body))
        for hour in 0...24 {
            let y = headerHeight + CGFloat(hour * 60) * pointsPerMinute - scrollY
            guard y >= headerHeight, y <= size.height else { continue }
            var line = Path(); line.move(to: CGPoint(x: axisWidth, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
            grid.stroke(line, with: .color(.white.opacity(0.15)), lineWidth: 1)
        }
        for (index, column) in layout.columns.enumerated() {
            let x = axisWidth + CGFloat(index) * columnWidth - scrollX
            guard x + columnWidth >= axisWidth, x <= size.width else { continue }
            for entry in column.entries {
                let rect = cellRect(entry, column: index, columnWidth: columnWidth)
                guard rect.maxY >= headerHeight, rect.minY <= size.height else { continue }
                drawEntry(entry, in: rect, context: grid, selected: false, now: now)
            }
        }
        let minute = now.timeIntervalSince(layout.baseDate) / 60
        let nowY = headerHeight + CGFloat(minute) * pointsPerMinute - scrollY
        if minute >= 0, minute <= 1440, nowY >= headerHeight, nowY <= size.height {
            var line = Path(); line.move(to: CGPoint(x: axisWidth, y: nowY)); line.addLine(to: CGPoint(x: size.width, y: nowY))
            grid.stroke(line, with: .color(.red), lineWidth: 2)
        }
        if layout.columns.indices.contains(position.column) {
            if let entry = layout.focusedEntry(position) {
                var rect = cellRect(entry, column: position.column, columnWidth: columnWidth)
                rect.size.height = max(140, min(rect.height, body.height * 0.8))
                rect.origin.y = min(max(headerHeight + 3, rect.minY), max(headerHeight + 3, size.height - rect.height - 3))
                drawEntry(entry, in: rect.insetBy(dx: 2, dy: 1), context: grid, selected: true, now: now)
            } else {
                let rect = CGRect(x: axisWidth + CGFloat(position.column) * columnWidth - scrollX + 2,
                                  y: headerHeight + CGFloat(position.minute) * pointsPerMinute - scrollY,
                                  width: columnWidth - 4, height: 100)
                label("番組情報なし", in: rect.insetBy(dx: 12, dy: 10), context: grid, font: .system(size: 20))
                grid.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(.cyan), lineWidth: 3)
            }
        }
        // 見出しはスクロール後に重ね、番組の下に隠れないようにする。
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: headerHeight)), with: .color(Color(white: 0.12)))
        context.fill(Path(CGRect(x: 0, y: headerHeight, width: axisWidth, height: max(0, size.height - headerHeight))), with: .color(Color(white: 0.12)))
        var headers = context
        headers.clip(to: Path(CGRect(x: axisWidth, y: 0, width: max(0, size.width - axisWidth), height: headerHeight)))
        for (index, column) in layout.columns.enumerated() {
            let x = axisWidth + CGFloat(index) * columnWidth - scrollX
            guard x + columnWidth >= axisWidth, x <= size.width else { continue }
            label(column.channel.name, in: CGRect(x: x + 10, y: 8, width: columnWidth - 20, height: headerHeight - 12),
                  context: headers, font: .system(size: 20, weight: .semibold))
        }
        label("時刻", in: CGRect(x: 10, y: 18, width: axisWidth - 12, height: 30), context: context, font: .system(size: 18))
        for hour in 0...24 {
            let y = headerHeight + CGFloat(hour * 60) * pointsPerMinute - scrollY
            guard y >= headerHeight, y < size.height - 18 else { continue }
            label("\((hour + 4) % 24)時", in: CGRect(x: 10, y: y + 4, width: axisWidth - 12, height: 30),
                  context: context, font: .system(size: 20, weight: .semibold))
        }
    }
    private func cellRect(_ entry: GuideGridEntry, column: Int, columnWidth: CGFloat) -> CGRect {
        CGRect(x: axisWidth + CGFloat(column) * columnWidth - scrollX + 1,
               y: headerHeight + CGFloat(entry.startMinute) * pointsPerMinute - scrollY + 1,
               width: columnWidth - 2, height: max(1, CGFloat(entry.endMinute - entry.startMinute) * pointsPerMinute - 2))
    }
    private func drawEntry(_ entry: GuideGridEntry, in rect: CGRect, context: GraphicsContext, selected: Bool, now: Date) {
        let color = genreColor(entry.program.genres.first?.major ?? "")
        let past = (entry.program.endDate ?? .distantFuture) <= now
        let background = selected ? Color(white: hasFocus ? 0.22 : 0.16) : color.opacity(past ? 0.10 : 0.24)
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(background))
        context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height)), with: .color(color))
        var cell = context
        cell.clip(to: Path(rect.insetBy(dx: 6, dy: 3)))
        let rawMinute = (entry.program.startDate ?? layout.baseDate).timeIntervalSince(layout.baseDate) / 60
        let clock = (Int(rawMinute) + 240 + 2880) % 1440
        let time = String(format: "%02d:%02d", clock / 60, clock % 60)
        label(time, in: CGRect(x: rect.minX + 12, y: rect.minY + 7, width: rect.width - 22, height: 22),
              context: cell, font: .system(size: 16), color: .white.opacity(0.75))
        label(entry.program.title, in: CGRect(x: rect.minX + 12, y: rect.minY + 30, width: rect.width - 22, height: max(0, rect.height - 38)),
              context: cell, font: .system(size: selected ? 23 : 21, weight: selected ? .bold : .medium), color: .white.opacity(past && !selected ? 0.55 : 1))
        if entry.program.reservation?.id != nil {
            context.stroke(Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 5),
                           with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        if selected {
            context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(hasFocus ? .cyan : .white.opacity(0.5)), lineWidth: 4)
        }
    }
    private func label(_ text: String, in rect: CGRect, context: GraphicsContext, font: Font, color: Color = .white) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.draw(context.resolve(Text(text).font(font).foregroundColor(color)), in: rect)
    }
    private func genreColor(_ genre: String) -> Color {
        if genre.contains("ニュース") { return .blue }
        if genre.contains("スポーツ") { return .orange }
        if genre.contains("アニメ") { return .pink }
        if genre.contains("映画") { return .purple }
        if genre.contains("ドラマ") { return .teal }
        if genre.contains("音楽") { return .indigo }
        if genre.contains("ドキュメンタリー") { return .green }
        if genre.contains("バラエティ") { return .yellow }
        return .gray
    }
}
