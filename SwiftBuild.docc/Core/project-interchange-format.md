# Project Interchange Format

The Project Interchange Format (PIF) is a structured representation of the project model created by clients to send to Swift Build.  A single PIF can represent a workspace and all of the projects inside it.


## Overview

### What's Included in a PIF

The PIF is a representation of the SwiftPM/Xcode project model describing the static objects which contribute to building products from the package/project, independent of "how" the user has chosen to build those products in any particular build.  This information can be cached by Swift Build between builds (even between builds which use different schemes or run destinations), and can be incrementally updated by clients when something changes.

The PIF format and exchange mechanisms are designed under the assumption that the PIF changes rarely relatively to other requests, because active edits to the project model are rare.


### What's Not Included

The PIF is only a representation of the project model, and does not contain all relevant information for a particular build.  Two classes of information are excluded.

First, information which persists throughout a run of the client, such as:

* **Environment variables:**
* **Specifications:** Including tool specs, product and package type specs, etc.
* **Platforms and SDK definitions**
* **Toolchain definitions**

This information is loaded by Swift Build directly via the *Core* object or explicitly sent through the service interface (in the case of environment variables).

Second, information which describes a particular build and which may change from build to build, and is sent as part of individual build requests:

* **Scheme information:** Which targets are to be built, whether Parallelize Targets and Implicit Dependencies are turned on.
* **Run Destination information:** Including the target device and the active architecture.
* **Build parameters:** Including the build action, per-target overrides of build settings, the workspace arena and more.


### Incremental Updates

The PIF format is designed to support incremental update of certain objects (like projects and targets). This mechanism is designed so that the service can maintain a *persistent* cache of objects, and efficiently negotiate with the client the smallest set of objects which need to be transferred in response to model changes.

The incremental update mechanism works by assigning unique *signatures* to each of the objects in the PIF which can be independently replaced. A single PIF can contain definitions for multiple objects, identified by signature. Within any individual object, references to other objects are encoded indirectly via the same signature. When a client wishes to transfer a PIF to Swift Build, it incrementally negotiates the exact set of objects which are required (i.e., missing from swift-build) using the [PIF exchange protocol](#exchange-protocol). Once all the required objects have been transferred, then Swift Build has a complete set of objects and can load the workspace.


<a name="global-identifiers"></a>

### Global Identifiers

Identifiers for objects in the PIF are needed to support looking up objects across top-level boundaries (such as project references). Objects that require this have an identifier (GUID) which is:

* *Unique* within the entire PIF.
* *Stable*, such that clients can generate the same GUID consistently for an object even if the object changes, unless that change makes it fundamentally a different object.

<a name="exchange-protocol"></a>

## Exchange Protocol

When a client wishes to transfer a PIF to Swift Build, it uses the PIF exchange protocol described here:

1. The client initiates a PIF transfer and sends a PIF containing the top-level object it wishes to transfer, typically the workspace.

2. Swift Build scans the set of objects it has received via the PIF transfer, and replies with a list of references which it does not have and requires transfer of.

3. The client transfers a PIF containing the additional requested objects.

4. Steps 2 and 3 repeat until Swift Build has all the objects it requires, at which point it acknowledges the receipt of the PIF and constructs the appropriate object.


## Format Description

The low-level encoding of the PIF is as [JSON](http://json.org).

PIFs are transferred using the [PIF exchange protocol](#exchange-protocol), and are encoded using the format described here.

Each PIF consists of a sequence of top-level objects (*PIFObject*). These define the objects which can be incrementally replaced by the PIF exchange protocol. Each entry in the PIF is a dictionary of the form:

* *signature*: A string signature uniquely representing the PIF object. This signature **must** completely define the PIF object; i.e. any other PIF entry with the same signature and type must define an identical object.
* *type*: The type of the top-level object. This is one of *workspace*, *project*, or *target*.
* *contents*: The contents of the object.



### Object Description

The remainder of this document defines the exact encoding for each object which can be represented in the PIF.

Objects which require it will have the following data in addition to their content:

* **GUID**: The object's [unique identifier](#global-identifiers) within the PIF.

For brevity, this item is not included in the structures described below.

Where the *value* of items below refer to a **GUID**, that indicates that the GUID of the referenced object has been captured and will be resolved by Swift Build to a concrete object elsewhere in the PIF.

The PIF structure has a few notable differences from the structure of the project model itself:

* Xcode models file references and product references as fairly similar objects with overlapping sets of data.  The PIF models these differently.  For example, neither product references nor proxies will have their own path and source tree information.
* Product references are not captured in the list of references of the project, but instead are captured as the product of the target which generates them.  Thus the fact that the reference is produced by the target is modeled by it being contained inside the target's PIF, and not by being a discrete references with a pointer to its producing target.  This more concisely captures the hierarchical relationship of the objects.
* There are no project references or reference proxies directly represented in the PIF, because since the whole workspace is being captured they can be fully resolved to the GUIDs of the objects they really represent.


#### Object References

Any place where an object can refer to a top-level PIF object uses the following encoding: If the item consists of a single string value, then that value is the signature for the object which is expected to be present at the top-level of the PIF (or previously loaded and available independently to the loader, in which case the PIF is incomplete).
