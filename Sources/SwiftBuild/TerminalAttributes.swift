//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SWBLibc

final class TerminalAttributes {
    #if !os(Windows)
    private var term_attrs = termios()
    #endif

    fileprivate init() {
    }

    fileprivate func save() {
        #if !os(Windows)
        if tcgetattr(STDIN_FILENO, &term_attrs) == -1 {
            // If we got an error here, just assume it is because the terminal wasn't capable.
            return
        }
        #endif
    }

    fileprivate func restore() {
        #if !os(Windows)
        // Ignore failures, there isn't anything we can do.
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &term_attrs)
        #endif
    }

    func disableEcho() {
        #if !os(Windows)
        // Get the current terminal attributes.
        var attrs = termios()
        if tcgetattr(STDIN_FILENO, &attrs) == -1 {
            // If we got an error here, just assume it is because the terminal wasn't capable.
            return
        }

        // Clear the echo flag and update the attributes.
        attrs.c_lflag &= ~tcflag_t(ECHO)
        if tcsetattr(STDIN_FILENO, TCSAFLUSH, &attrs) == -1 {
            perror("tcsetattr")
            return
        }
        #endif
    }
}

/// Save the active terminal attributes before executing `block` and restore them afterwards.
func withTerminalAttributes<T>(_ block: (TerminalAttributes) async throws -> T) async throws -> T {
    let terminalAttributes = TerminalAttributes()
    terminalAttributes.save()
    defer { terminalAttributes.restore() }
    return try await block(terminalAttributes)
}
