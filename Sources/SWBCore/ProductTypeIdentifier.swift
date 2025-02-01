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

/// Represents a product type identifier string that identifies a product type spec.
public struct ProductTypeIdentifier: Equatable {
    public let stringValue: String

    public init(_ string: String) {
        self.stringValue = string
    }
}

public extension ProductTypeIdentifier {
    var supportsInstallAPI: Bool {
        // Static frameworks/libraries need to run installAPI if they contain Swift source code because we need .swiftmodule to build downstream targets.
        return stringValue == "com.apple.product-type.framework"
            || stringValue == "com.apple.product-type.framework.static"
            || stringValue == "com.apple.product-type.library.dynamic"
            || stringValue == "com.apple.product-type.library.static"
            // Swift packages need to run installAPI.
            || stringValue == "com.apple.product-type.objfile"
    }

    var supportsEagerLinking: Bool {
        return stringValue == "com.apple.product-type.framework"
            || stringValue == "com.apple.product-type.library.dynamic"
    }

    var isHostBuildTool: Bool {
        stringValue == "com.apple.product-type.tool.host-build"
    }
}
