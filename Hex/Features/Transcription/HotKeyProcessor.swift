//
//  HotKeyProcessor.swift
//  Hex
//
//  Created by Kit Langton on 1/28/25.
//
import Dependencies
import Foundation
import SwiftUI

/// Implements both "Press-and-Hold" and "Double-Tap Lock" in a single state machine.
///
/// Double-tap logic:
/// - A "tap" is recognized if we see chord == hotkey => chord != hotkey quickly.
/// - We track the **release time** of each tap in `lastTapAt`.
/// - On the second release, if the time since the prior release is < `doubleTapThreshold`,
///   we switch to .doubleTapLock instead of stopping.
///   (No new .startRecording output — we remain in a locked recording state.)
///
/// Press-and-Hold logic remains the same:
/// - If chord == hotkey while idle => .startRecording => state=.pressAndHold.
/// - If, within 1 second, the user changes chord => .stopRecording => idle => dirty
///   so we don't instantly re-match mid-press.
/// - If the user "releases" the hotkey chord => .stopRecording => idle => track release time.
///   That release time is used to detect a second quick tap => possible doubleTapLock.
///
/// Additional details:
/// - For modifier-only hotkeys, “release” is chord = (key:nil, modifiers:[]).
/// - Pressing ESC => immediate .cancel => resetToIdle().
/// - "Dirty" logic is unchanged from the prior iteration, so we still ignore any chord
///   until the user fully releases (key:nil, modifiers:[]).

public struct HotKeyProcessor {
    @Dependency(\.date.now) var now

    public var hotkey: HotKey
    public var useDoubleTapOnly: Bool = false

    public private(set) var state: State = .idle
    private var lastTapAt: Date? // Time of the most recent release
    private var isDirty: Bool = false

    public static let doubleTapThreshold: TimeInterval = 0.3
    public static let pressAndHoldCancelThreshold: TimeInterval = 1.0

    public init(hotkey: HotKey, useDoubleTapOnly: Bool = false) {
        self.hotkey = hotkey
        self.useDoubleTapOnly = useDoubleTapOnly
    }

    public var isMatched: Bool {
        switch state {
        case .idle:
            return false
        case .pressAndHold, .doubleTapLock:
            return true
        }
    }

    public mutating func process(keyEvent: KeyEvent) -> Output? {
        // 1) ESC => immediate cancel
        if keyEvent.key == .escape {
            print("ESCAPE HIT IN STATE: \(state)")
        }
        if keyEvent.key == .escape, state != .idle {
            resetToIdle()
            return .cancel
        }

        // 2) If dirty, ignore until full release (nil, [])
        if isDirty {
            if chordIsFullyReleased(keyEvent) {
                isDirty = false
            } else {
                return nil
            }
        }

        // 3) Matching chord => handle as "press"
        if chordMatchesHotkey(keyEvent) {
            return handleMatchingChord()
        } else {
            // Potentially become dirty if chord has extra mods or different key
            if chordIsDirty(keyEvent) {
                isDirty = true
            }
            return handleNonmatchingChord(keyEvent)
        }
    }
}

// MARK: - State & Output

public extension HotKeyProcessor {
    enum State: Equatable {
        case idle
        case pressAndHold(startTime: Date)
        case doubleTapLock
    }

    enum Output: Equatable {
        case startRecording
        case stopRecording
        case cancel
    }
}

// MARK: - Core Logic

extension HotKeyProcessor {
    /// If we are idle and see chord == hotkey => pressAndHold (or potentially normal).
    /// We do *not* lock on second press. That is deferred until the second release.
    private mutating func handleMatchingChord() -> Output? {
        switch state {
        case .idle:
            // If doubleTapOnly mode is enabled and the hotkey has a key component,
            // we want to delay starting recording until we see the double-tap
            if useDoubleTapOnly && hotkey.key != nil {
                // Record the timestamp but don't start recording
                lastTapAt = now
                return nil
            } else {
                // Normal press => .pressAndHold => .startRecording
                state = .pressAndHold(startTime: now)
                return .startRecording
            }

        case .pressAndHold:
            // Already matched, no new output
            return nil

        case .doubleTapLock:
            // Pressing hotkey again while locked => stop
            resetToIdle()
            return .stopRecording
        }
    }

    /// Called when chord != hotkey. We check if user is "releasing" or "typing something else".
    private mutating func handleNonmatchingChord(_ e: KeyEvent) -> Output? {
        switch state {
        case .idle:
            // Handle double-tap detection for key+modifier combinations
            if useDoubleTapOnly && hotkey.key != nil && 
               chordIsFullyReleased(e) && 
               lastTapAt != nil {
                // If we've seen a tap recently, and now we see a full release, and we're in idle state
                // Check if the time between taps is within the threshold
                if let prevTapTime = lastTapAt,
                   now.timeIntervalSince(prevTapTime) < Self.doubleTapThreshold {
                    // This is the second tap - activate recording in double-tap lock mode
                    state = .doubleTapLock
                    return .startRecording
                }
                
                // Reset the tap timer as we've fully released
                lastTapAt = nil
            }
            return nil

        case let .pressAndHold(startTime):
            // If user truly "released" the chord => either normal stop or doubleTapLock
            if isReleaseForActiveHotkey(e) {
                // Check if this release is close to the prior release => double-tap lock
                if let prevReleaseTime = lastTapAt,
                   now.timeIntervalSince(prevReleaseTime) < Self.doubleTapThreshold
                {
                    // => Switch to doubleTapLock, remain matched, no new output
                    state = .doubleTapLock
                    return nil
                } else {
                    // Normal stop => idle => record the release time
                    state = .idle
                    lastTapAt = now
                    return .stopRecording
                }
            } else {
                // If within 1s, treat as cancel hold => stop => become dirty
                let elapsed = now.timeIntervalSince(startTime)
                if elapsed < Self.pressAndHoldCancelThreshold {
                    isDirty = true
                    resetToIdle()
                    return .stopRecording
                } else {
                    // After 1s => remain matched
                    return nil
                }
            }

        case .doubleTapLock:
            // For key+modifier combinations in doubleTapLock mode, require full key release to stop
            if useDoubleTapOnly && hotkey.key != nil && chordIsFullyReleased(e) {
                resetToIdle()
                return .stopRecording
            }
            // Otherwise, if locked, ignore everything except chord == hotkey => stop
            return nil
        }
    }

    // MARK: - Helpers

    private func chordMatchesHotkey(_ e: KeyEvent) -> Bool {
        e.key == hotkey.key && e.modifiers == hotkey.modifiers
    }

    /// "Dirty" if chord includes any extra modifiers or a different key.
    private func chordIsDirty(_ e: KeyEvent) -> Bool {
        // Check if event has extra modifiers beyond what the hotkey requires
        let hasExtraModifiers = !e.modifiers.isSubset(of: hotkey.modifiers)
        
        // Check if event has a different key when hotkey expects a specific key
        let isWrongKey = (hotkey.key != nil && e.key != nil && e.key != hotkey.key)
        
        // Check if event has a key when hotkey is modifier-only, BUT exclude the case where
        // event modifiers are empty (like arrow keys with no modifiers)
        let hasKeyForModifierOnlyHotkey = (hotkey.key == nil && e.key != nil && !e.modifiers.isEmpty)
        
        return hasExtraModifiers || isWrongKey || hasKeyForModifierOnlyHotkey
    }

    private func chordIsFullyReleased(_ e: KeyEvent) -> Bool {
        e.key == nil && e.modifiers.isEmpty
    }

    /// For a key+modifier hotkey, "release" => same modifiers, no key.
    /// For a modifier-only hotkey, "release" => no modifiers at all.
    private func isReleaseForActiveHotkey(_ e: KeyEvent) -> Bool {
        if hotkey.key != nil {
            // standard hotkey => release means chord = (nil, same modifiers)
            return e.key == nil && e.modifiers == hotkey.modifiers
        } else {
            // modifier-only => release means chord= (nil, [])
            return e.key == nil && e.modifiers.isSubset(of: hotkey.modifiers)
        }
    }

    /// Clear state but preserve `isDirty` if the caller has just set it.
    private mutating func resetToIdle() {
        state = .idle
        lastTapAt = nil
    }
}
