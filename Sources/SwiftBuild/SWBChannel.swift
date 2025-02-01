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

import SWBProtocol

/// Represents an open communication channel.
///
/// The event stream is infinite (consumer finished) by design.
final class SWBChannel {
    let service: SWBBuildService
    let stream: AsyncStream<(any Message)?>
    private let channel: UInt64

    init(service: SWBBuildService) {
        self.service = service
        let (stream, continuation) = AsyncStream<(any Message)?>.makeStream()
        self.stream = stream
        self.channel = service.openChannel(handler: {
            if case .terminated = continuation.yield($0) {
                continuation.finish()
            }
        })
    }

    func send(_ makeMessage: (UInt64) -> any SessionChannelMessage) async -> any Message {
        await send(makeMessage(channel))
    }

    func send(_ message: any SessionChannelMessage) async -> any Message {
        await service.send(message)
    }

    deinit {
        service.closeChannel(channel)
    }
}
