//
//  SymRooms.swift
//  SYM
//
//  The room name → Bonjour service type mapping, and the grammar that decides
//  which names are legal. This is the Swift half of a CROSS-IMPLEMENTATION
//  CONTRACT: it must agree character-for-character with `lib/rooms.js` in the
//  sym Node package, because a room name IS the DNS-SD service type. Two
//  implementations that compute it differently do not disagree loudly — they
//  simply never see each other, with no error raised on either side.
//
//  Why this file exists at all: it did not, and every Swift consumer therefore
//  wrote its own. Six hand-rolled copies were found across the SYM.BOT tree in
//  August 2026 and every one of them disagreed with at least one other —
//  `default` mapping to `_default._tcp` in two of them (so the room a new user
//  is most likely to type was the one room they could never join), one
//  truncating long names to a digest that no other implementation emits, and
//  several silently "repairing" names into different rooms. A shared mapping
//  that is hard to reach is a mapping that gets copied, so this one is public,
//  dependency-free and has no setup.
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import Foundation

/// Room naming for the SYM mesh. A namespace, not a type to instantiate.
public enum SymRooms {

    /// The global mesh: the room every node is in when none is named.
    public static let defaultRoom = "default"

    /// The service type the global mesh advertises on.
    public static let defaultServiceType = "_sym._tcp"

    /// Lowercase alphanumeric segments joined by ONE or TWO hyphens.
    ///
    /// The double hyphen is a segment separator with meaning: it separates a
    /// base room name from a tenant suffix, so `x-review` scoped to a team
    /// becomes `x-review--team-<teamId>`. Three or more consecutive hyphens, a
    /// leading or trailing hyphen, uppercase, underscores and dots are all
    /// invalid. Kept identical to KEBAB_CASE_RE in lib/rooms.js.
    public static let grammar = "^[a-z0-9]+(?:--?[a-z0-9]+)*$"

    /// Whether a room name is legal AND canonical.
    ///
    /// Canonical means one name per room and one room per name: the name a
    /// node declares must be the name that comes back out of the service type
    /// it advertises on. Grammar alone does not give that — `sym` satisfies the
    /// grammar, maps to `_sym._tcp`, and comes back as `default`, so it is a
    /// second spelling of the global mesh. A node asking for a room named
    /// `sym` would believe it was somewhere specific while sitting in the
    /// public square, and nothing on any path would report it.
    ///
    /// Founder ruling 2026-08-27: room names must be canonical.
    public static func isValidRoom(_ room: String) -> Bool {
        if room == defaultRoom { return true }
        guard room.range(of: grammar, options: .regularExpression) != nil else { return false }
        return serviceTypeToRoom(roomServiceType(room)) == room
    }

    /// The canonical name for a room, or nil if this string does not name one.
    ///
    /// The sanctioned way to accept a name from outside — a UI field, a config
    /// value, an invite URL. Surrounding whitespace is not part of a name and
    /// is trimmed; nothing else is altered.
    ///
    /// It returns nil rather than a best effort **on purpose**. Do not "repair"
    /// a rejected name by lowercasing it, substituting illegal characters, or
    /// shortening it to fit: every such repair is many-to-one, so it sends
    /// people who asked for different rooms into the same room and tells none
    /// of them. Refusing costs one error message; repairing costs a room that
    /// quietly is not the one that was asked for.
    public static func canonicalRoom(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidRoom(name) ? name : nil
    }

    /// Map a room name to its Bonjour service type.
    ///
    /// Pass a name that has been through `canonicalRoom(_:)`. This mirrors the
    /// JS implementation exactly, including that it does not validate — so an
    /// unvalidated name produces an unvalidated type, which is how malformed
    /// types reach the wire.
    public static func roomServiceType(_ room: String) -> String {
        (room.isEmpty || room == defaultRoom) ? defaultServiceType : "_\(room)._tcp"
    }

    /// Inverse: derive a room name from a service type (`_acme._tcp` → "acme").
    public static func serviceTypeToRoom(_ serviceType: String) -> String {
        guard !serviceType.isEmpty, serviceType != defaultServiceType else { return defaultRoom }
        var s = Substring(serviceType)
        if s.hasPrefix("_") { s = s.dropFirst() }
        if s.hasSuffix("._tcp") { s = s.dropLast(5) }
        return String(s)
    }

    // MARK: - Platform reachability

    /// Whether `serviceType` can actually be used by this process.
    ///
    /// On Apple platforms subject to local network privacy, `NSBonjourServices`
    /// in Info.plist is a **build-time allow-list with no wildcard**, so a
    /// service type absent from it can neither be browsed nor advertised, and
    /// the failure surfaces as an empty browse or a NoAuth error rather than as
    /// a clear rejection. The gate is local network privacy, NOT the App
    /// Sandbox — apps declaring no sandbox entitlement are bound by it just the
    /// same, so there is no sandbox setting to relax.
    ///
    /// The practical consequence is worth stating plainly: **a room named at
    /// runtime cannot be joined inside such an app**, however valid its name.
    /// Ask this before joining, and tell the user, rather than starting a node
    /// that can never discover anyone.
    ///
    /// Reads the running bundle rather than a list duplicated in code, because
    /// a second copy would go on reporting "declared" after someone edited the
    /// plist. Returns nil where the host declares no list at all — an
    /// unsandboxed daemon or CLI, which is unconstrained — so callers can tell
    /// "not declared" apart from "no allow-list applies".
    public static func declaredServiceTypes(in bundle: Bundle = .main) -> Set<String>? {
        guard let declared = bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        else { return nil }
        return Set(declared)
    }

    /// Whether a room can be joined on this build: canonical AND reachable.
    ///
    /// Two independent facts, deliberately composed rather than merged, so a
    /// caller can tell a mistyped name from a platform limit. Reporting one as
    /// the other sends whoever reads the error to edit a file that was never
    /// the problem.
    public static func canJoinRoom(_ name: String, in bundle: Bundle = .main) -> Bool {
        guard let room = canonicalRoom(name) else { return false }
        guard let declared = declaredServiceTypes(in: bundle) else { return true }
        return declared.contains(roomServiceType(room))
    }
}
