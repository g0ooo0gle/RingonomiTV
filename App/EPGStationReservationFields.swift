import SwiftUI
import RingonomiCore

struct EPGStationScheduleProgramChoice: View {
    let program: EPGStationScheduleProgram
    let select: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button {
            select()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(program.name).font(.headline)
                Text(epgStationSchedule(start: program.startAt, end: program.endAt)).font(.caption)
                if !program.isFree { Text("有料放送").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct EPGStationChoiceList<Value: Hashable>: View {
    let title: String
    let values: [(Value, String)]
    let selection: Value?
    let select: (Value) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(Array(values.enumerated()), id: \.offset) { _, item in
            Button {
                select(item.0)
                dismiss()
            } label: {
                HStack {
                    Text(item.1)
                    if selection == item.0 { Image(systemName: "checkmark") }
                }
            }
        }.navigationTitle(title)
    }
}

var epgStationCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
}

struct EPGStationDateTimeField: View {
    let title: String
    @Binding var date: Date
    private var parts: DateComponents { epgStationCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date) }
    private var dayValues: [(Date, String)] {
        (0..<14).map { offset in
            let day = epgStationCalendar.date(byAdding: .day, value: offset, to: epgStationCalendar.startOfDay(for: Date()))!
            return (day, reservationDate(day))
        }
    }
    private var hourValues: [(Int, String)] { (0..<24).map { ($0, String(format: "%02d時", $0)) } }
    private var minuteValues: [(Int, String)] { (0..<60).map { ($0, String(format: "%02d分", $0)) } }

    var body: some View {
        NavigationLink(title + "：" + reservationDate(date)) {
            List {
                NavigationLink("日付") { dayChoice }
                NavigationLink("時：\(parts.hour ?? 0)") { hourChoice }
                NavigationLink("分：\(parts.minute ?? 0)") { minuteChoice }
            }.navigationTitle(title + "時刻")
        }
    }

    private var dayChoice: some View {
        EPGStationChoiceList(title: "日付", values: dayValues, selection: epgStationCalendar.startOfDay(for: date)) { day in
            var next = epgStationCalendar.dateComponents([.year, .month, .day], from: day)
            next.hour = parts.hour
            next.minute = parts.minute
            if let value = epgStationCalendar.date(from: next) { date = value }
        }
    }
    private var hourChoice: some View {
        EPGStationChoiceList(title: "時", values: hourValues, selection: parts.hour) { hour in
            var next = parts
            next.hour = hour
            if let value = epgStationCalendar.date(from: next) { date = value }
        }
    }
    private var minuteChoice: some View {
        EPGStationChoiceList(title: "分", values: minuteValues, selection: parts.minute) { minute in
            var next = parts
            next.minute = minute
            if let value = epgStationCalendar.date(from: next) { date = value }
        }
    }
}
