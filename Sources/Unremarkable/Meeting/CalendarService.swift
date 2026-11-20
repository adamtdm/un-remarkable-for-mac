import AppKit
import EventKit
import Foundation
import Observation
import RMKit
import SwiftUI
import UserNotifications

/// A calendar event you might want to record.
struct UpcomingMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
    let calendar: String
    let hasVideoLink: Bool

    var isNow: Bool { start <= .now.addingTimeInterval(120) && end > .now }
}

/// Reads your calendars and prompts you to record meetings as they start.
@MainActor @Observable
final class CalendarService: NSObject {
    static let shared = CalendarService()
    nonisolated static let recordAction = "RECORD"
    nonisolated static let category = "MEETING_START"

    private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private(set) var upcoming: [UpcomingMeeting] = []
    @ObservationIgnored @AppStorage("calendarPrompts") var promptsEnabled = true
    @ObservationIgnored @AppStorage("calendarLeadMinutes") var leadMinutes = 1
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var notified: Set<String> = []

    var hasAccess: Bool { access == .fullAccess }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [record], intentIdentifiers: [])])
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarService.shared.tick() }
        }
        refresh()
    }

    /// Asks for calendar and notification access (macOS shows its prompts once).
    func requestAccess() async {
        do { _ = try await store.requestFullAccessToEvents() } catch {}
        access = EKEventStore.authorizationStatus(for: .event)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        refresh()
    }

    func refresh() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { upcoming = []; return }
        let now = Date.now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(24 * 3600), calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !declined($0) }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                let text = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
                return UpcomingMeeting(
                    id: e.calendarItemIdentifier + "|" + String(e.startDate.timeIntervalSince1970),
                    title: e.title ?? "Meeting", start: e.startDate, end: e.endDate,
                    attendees: (e.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
                    calendar: e.calendar.title,
                    hasVideoLink: ["zoom.us", "meet.google", "teams.microsoft", "webex"].contains { text.contains($0) })
            }
        tick()
    }

    private func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first { $0.isCurrentUser }?.participantStatus == .declined
    }

    private func tick() {
        guard promptsEnabled, hasAccess, !MeetingRecorder.shared.isRecording else { return }
        let lead = TimeInterval(leadMinutes * 60)
        for m in upcoming where !notified.contains(m.id) && m.start.timeIntervalSinceNow <= lead && m.start.timeIntervalSinceNow > -300 {
            notified.insert(m.id)
            notify(m)
        }
    }

    private func notify(_ m: UpcomingMeeting) {
        let content = UNMutableNotificationContent()
        content.title = m.title
        content.body = m.start > .now ? "Starts at \(m.start.formatted(date: .omitted, time: .shortened)). Record it to get notes on your tablet."
                                     : "Started at \(m.start.formatted(date: .omitted, time: .shortened)). Record it to get notes on your tablet."
        content.categoryIdentifier = Self.category
        content.userInfo = ["meetingID": m.id]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: m.id, content: content, trigger: nil))
    }

    /// Starts recording a calendar meeting: title and attendees from the event, linked to the reMarkable
    /// notebook the tablet created for it (so notes are added there).
    func record(_ m: UpcomingMeeting) {
        let recorder = MeetingRecorder.shared
        guard !recorder.isRecording else { return }
        var meeting = recorder.newMeeting(title: m.title)
        meeting.calendarEventID = m.id
        meeting.attendees = m.attendees
        if meeting.myNotes.isEmpty, !m.attendees.isEmpty { meeting.myNotes = "" }
        meeting.linkedDocumentID = Self.calendarNotebook(title: m.title, date: m.start)?.id
        recorder.update(meeting)
        AppModel.shared.openMeeting(meeting.id)
        Task { await recorder.start(meeting.id) }
    }


    /// The notebook the tablet's calendar integration made for this event: same title, and its first
    /// lines carry the date ("Meeting | 2026-09-09"). Falls back to a same-titled notebook from that day.
    static func calendarNotebook(title: String, date: Date) -> DocumentItem? {
        let model = AppModel.shared
        let want = title.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = model.documents.filter {
            $0.kind == .notebook && !$0.isTrashed && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == want
        }
        let day = date.formatted(.iso8601.year().month().day())
        if let dated = candidates.first(where: { (model.db.body($0.id) ?? "").contains(day) }) { return dated }
        return candidates.filter { Calendar.current.isDate($0.lastModified, inSameDayAs: date) || abs($0.lastModified.timeIntervalSince(date)) < 86_400 }
            .max { $0.lastModified < $1.lastModified }
    }
}

extension CalendarService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["meetingID"] as? String
        let tapped = response.actionIdentifier == CalendarService.recordAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        await MainActor.run {
            guard tapped, let id, let m = CalendarService.shared.upcoming.first(where: { $0.id == id }) else { return }
            CalendarService.shared.record(m)
        }
    }
}
