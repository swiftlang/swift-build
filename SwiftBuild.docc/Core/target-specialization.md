# Build Target Specialization

Target specialization is the feature which allows Swift Build to build multiple
instances of a target within a single build.

This is used as part of Xcode's Swift package support to provide
"build to order" features for Swift packages, as well as multi-platform targets.

## Overview

Within Swift Build, we maintain a distinction between the `Target` model object and
the `ConfiguredTarget` which is a specific instance of a target plus build
parameters, as used within a particular build. While Xcode traditionally only
ever would allow one target to exist in one instance in a build, Swift Build can
allow the target to participate multiple times.

Conceptually, the `Target` can be thought of as the template for how the
something is built, and the `ConfiguredTarget` is a specific instance of that
template based on the run destination and other build parameters.

We use this generally capability in order to provide the "build to order"
feature used by Swift packages, as well as multi-platform targets.

## Mechanism

Target specialization occurs as part of resolving an incoming build request into
a complete `TargetBuildGraph`.

The mechanism by which this happens is that `PackageProductTarget` are
considered to be a "build to order" target type. When a target depends on a
`PackageProductTarget`, rather than use the targets own settings to determine
how it is built, it propagates _some of_ the settings from the target which
depends on it. This propagation continues along the full dependency chain, and
thus it impacts the `StandardTarget` instances used by the product type.

## Platform-Based Limitation

Target specialization currently *only* allows specializing based on the
platform. That is, we will at most produce one instance of a target per
platform.

While there are valid scenarios in which one could want a target to be built
multiple time for a single platform (one could imagine an XPC service that has a
newer deployment target, and could benefit by compiling its dependency for a
newer version), this limitation:

1. Allows us to piggy back on the existing platform-specific build directories,
   rather than have to invent a new mechanism to segregate different
   specializations.
2. Is conceptually simple to understand, which was desirable for the first
   attempts to take advantage of our `Target` vs `ConfiguredTarget`
   architecture.
3. Allows us to avoid the complicated question of exactly when we should be
   trying to create a separate specialization based on the wide variety of
   settings (or even based on user authored intent).

## Specialization Consolidation

Although conceptually targets are specialized based on the parameters of their
dependents, this mechanism alone would result in more specialized targets than
we currently support (or would want to support). For example, a package product
depended upon by a target with a 10.11 deployment target and a 10.12 deployment
target should typically only build the dependency for 10.11, rather than attempt
to specialize twice.

We implement this by first doing a prepass over the dependency graph, to gather
all of the configured targets before performing any specialization. Once
complete, we run the real dependency graph computation, which then searches
configured targets before it ever creates a specialization. We can extend this
over time to support a more complex aggregation of the specializations.

Finally, once this process is complete we perform a post-processing pass to
check that all of the specializations are valid. For example, in the current
implementation it is an serious bug to ever have ended up with multiple
specializations in the same platform.
