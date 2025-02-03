#!/bin/sh

export SWIFT_CI=1

swift test --very-verbose
