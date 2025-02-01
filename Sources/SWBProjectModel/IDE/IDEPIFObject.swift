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

import Foundation


/// Protocol describing top-level PIF objects.
public protocol IDEPIFObject : IDEPIFGenerating {
    /// The name of the PIF object type (workspace, project, or target).
    static var pifObjectTypeName: String { get }
    /// Returns the list of subobjects.
    var pifSubobjects: [any IDEPIFObject] { get }
    /// Returns the PIF object info for the object.
    func pifInfo<T: IDEPIFSerializer>(for serializer: T) -> IDEPIFObjectInfo
}
