//
//  ForegroundAppClient.swift
//  Hex
//
//  Detects the foreground application and infers an appropriate
//  output style for AI enhancement prompts.
//

import AppKit
import Dependencies
import DependenciesMacros
import Foundation

/// Minimal information about the foreground application.
struct ForegroundAppInfo: Equatable, Sendable {
    var bundleIdentifier: String = ""
    var localizedName: String = ""
}

/// A client that detects the foreground application and infers output style.
@DependencyClient
struct ForegroundAppClient {
    /// Capture the current foreground application info.
    var getForegroundApp: @Sendable () async -> ForegroundAppInfo = { ForegroundAppInfo() }

    /// Infer an output style from the application info.
    var inferOutputStyle: @Sendable (ForegroundAppInfo) -> OutputStyle = { _ in .general }
}

// MARK: - Live Implementation

extension ForegroundAppClient: DependencyKey {
    static var liveValue: Self {
        Self(
            getForegroundApp: {
                await MainActor.run {
                    let app = NSWorkspace.shared.frontmostApplication
                    return ForegroundAppInfo(
                        bundleIdentifier: app?.bundleIdentifier ?? "",
                        localizedName: app?.localizedName ?? ""
                    )
                }
            },
            inferOutputStyle: { info in
                ForegroundAppStyleMapper.infer(from: info)
            }
        )
    }
}

extension DependencyValues {
    var foregroundApp: ForegroundAppClient {
        get { self[ForegroundAppClient.self] }
        set { self[ForegroundAppClient.self] = newValue }
    }
}

// MARK: - Style Mapper

enum ForegroundAppStyleMapper {

    /// Bundle-ID → OutputStyle mapping.
    private static let mapping: [String: OutputStyle] = [
        // Formal
        "com.apple.mail": .formal,
        "com.microsoft.Outlook": .formal,
        "com.apple.iWork.Pages": .formal,
        "com.microsoft.Word": .formal,
        "com.google.Chrome.app.gmail": .formal,

        // Casual
        "com.apple.MobileSMS": .casual,
        "com.tinyspeck.slackmacgap": .casual,
        "com.hnc.Discord": .casual,
        "jp.naver.line.mac": .casual,
        "com.facebook.archon": .casual,
        "org.whispersystems.signal-desktop": .casual,
        "ru.keepcoder.Telegram": .casual,
        "com.hammerandchisel.discord": .casual,

        // Technical
        "com.apple.dt.Xcode": .technical,
        "com.microsoft.VSCode": .technical,
        "com.microsoft.VSCodeInsiders": .technical,
        "dev.zed.Zed": .technical,
        "com.apple.Terminal": .technical,
        "com.googlecode.iterm2": .technical,
        "io.alacritty": .technical,
        "net.kovidgoyal.kitty": .technical,
        "com.jetbrains.intellij": .technical,

        // Notes
        "com.apple.Notes": .notes,
        "notion.id": .notes,
        "md.obsidian": .notes,
        "com.apple.iWork.Keynote": .notes,
    ]

    static func infer(from info: ForegroundAppInfo) -> OutputStyle {
        // Direct match
        if let style = mapping[info.bundleIdentifier] {
            return style
        }

        // Partial match for common patterns
        let bid = info.bundleIdentifier.lowercased()
        if bid.contains("terminal") || bid.contains("iterm") { return .technical }
        if bid.contains("slack") || bid.contains("discord") || bid.contains("telegram") { return .casual }
        if bid.contains("mail") { return .formal }
        if bid.contains("note") || bid.contains("obsidian") || bid.contains("notion") { return .notes }

        return .general
    }
}
