#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation
import HomelabKit

/// The "Leave by" Live Activity (step 6c). Shared by the app (starts, updates and ends it) and the widget extension
/// (draws it). Local only: no push, so no Push capability and no extra App ID.
public struct LeaveAttributes: ActivityAttributes {
    public typealias ContentState = LeaveContent

    /// Static for the whole activity: the day it belongs to and when the first lesson begins.
    public var day: String
    public var firstLesson: Date

    public init(day: String, firstLesson: Date) {
        self.day = day
        self.firstLesson = firstLesson
    }
}
#endif
