import Foundation

func reservationDate(_ date: Date?) -> String {
    guard let date else { return "時刻未定" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "M/d(E) HH:mm"
    return formatter.string(from: date)
}
func reservationTime(_ date: Date?) -> String {
    guard let date else { return "時刻未定" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
