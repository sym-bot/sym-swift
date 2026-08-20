//
//  SymInviteURL.swift
//  SYM
//
//  The `sym://` invite link — one parser/formatter shared by every app,
//  so no app carries its own regex and two apps cannot disagree about
//  what a link means.
//  Reviewed surface: sym-swift 0.5.0 API sketch §5 (dev2 wire contract).
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import Foundation

/// A parsed `sym://invite/v1` link carrying everything a node needs to join
/// someone else's mesh: the relay to dial, the token to present, optionally
/// the room partition inside that token's channel, and optionally a
/// display-only name for the join sheet.
///
/// Canonical form emits parameters in a fixed order
/// (`relay, token, room, name`) so ``url`` round-trips byte-stably — QR
/// codes and `Equatable` comparisons depend on it.
///
/// ```
/// sym://invite/v1?relay=wss%3A%2F%2Frelay.example%2Fmesh&token=abc&room=studio&name=Emma%27s%20circle
/// ```
public struct SymInviteURL: Sendable, Equatable {

    /// The invite format version this type reads and writes.
    public static let version = "v1"

    /// Relay endpoint to dial. Always `wss` — see ``init(parsing:)``.
    public let relay: URL
    /// Bearer credential admitting the holder to the relay channel.
    /// Redacted from ``description`` and never logged by SYM.
    public let token: String
    /// Room partition inside the token's channel. `nil` means the invite
    /// names no partition — NEVER the empty partition, which is a real,
    /// different place. See ``init(parsing:)``.
    public let room: String?
    /// Display-only label for the join sheet ("Join Emma's circle?").
    /// NOT a credential: it may be logged and is not authenticated.
    public let name: String?

    /// Build an invite link.
    public init(relay: URL, token: String, room: String? = nil, name: String? = nil) {
        self.relay = relay
        self.token = token
        self.room = room
        self.name = name
    }

    /// Parse a `sym://` invite link. Returns nil for anything malformed —
    /// the caller shows "this link isn't valid", never a half-understood join.
    ///
    /// Refusals worth knowing:
    /// - Unknown version segment. Forward compatibility is by version, not
    ///   by guessing at a shape this build predates.
    /// - A PRESENT-but-EMPTY `room=`. The empty string is itself a real
    ///   relay partition — the unnamed one every pre-room client occupies —
    ///   so reading `room=` as "no room" would silently join the holder to
    ///   everyone. Absent means nil; present-but-empty is malformed.
    /// - A non-`wss` relay. A plaintext relay would carry the token in the
    ///   clear, which no amount of redaction downstream can undo.
    public init?(parsing url: URL) {
        guard url.scheme?.lowercased() == "sym",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // sym://invite/v1 parses as host "invite" + path "/v1".
        let segments = ([components.host] + components.path.split(separator: "/").map(String.init))
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard segments.count == 2,
              segments[0].lowercased() == "invite",
              segments[1].lowercased() == Self.version else { return nil }

        let items = components.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }

        guard let relayString = value("relay"), !relayString.isEmpty,
              let relayURL = URL(string: relayString),
              relayURL.scheme?.lowercased() == "wss",
              let token = value("token"), !token.isEmpty else { return nil }

        // Distinguish absent from present-but-empty: `items.first` finding
        // nothing is absent; finding a param whose value is "" or nil is a
        // malformed invite, not a defaulted one.
        if items.contains(where: { $0.name == "room" }) {
            guard let room = value("room"), !room.isEmpty else { return nil }
            self.room = room
        } else {
            self.room = nil
        }

        if items.contains(where: { $0.name == "name" }) {
            guard let name = value("name"), !name.isEmpty else { return nil }
            self.name = name
        } else {
            self.name = nil
        }

        self.relay = relayURL
        self.token = token
    }

    /// The canonical link. Parameter order is fixed at `relay, token, room,
    /// name` and optional parameters are omitted (never emitted empty), so
    /// formatting a parsed link reproduces it byte for byte.
    public var url: URL {
        var components = URLComponents()
        components.scheme = "sym"
        components.host = "invite"
        components.path = "/\(Self.version)"
        var items = [
            URLQueryItem(name: "relay", value: relay.absoluteString),
            URLQueryItem(name: "token", value: token),
        ]
        if let room { items.append(URLQueryItem(name: "room", value: room)) }
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        components.queryItems = items
        // Force-unwrap is safe: scheme/host/path are literals here and the
        // query items are percent-encoded by URLComponents.
        return components.url!
    }
}

extension SymInviteURL: CustomStringConvertible {
    /// Debug description with the token REDACTED — an invite link is a
    /// bearer credential, and the most common way one leaks is a log line
    /// written by a developer who never thought of it as a secret.
    public var description: String {
        "SymInviteURL(relay: \(relay.absoluteString), token: <redacted>, room: \(room ?? "nil"), name: \(name ?? "nil"))"
    }
}
