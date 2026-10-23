#!/bin/sh
set -eu

test_dir="$(mktemp -d /tmp/grassIsland-regressions.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

swiftc -D GRASS_ISLAND_REGRESSION \
  Sources/grassIsland/DeveloperMode.swift \
  Sources/grassIsland/InboxNotifications.swift \
  Sources/grassIsland/grassIsland.swift \
  Tests/grassIslandTests/RegressionRunner.swift \
  -o "$test_dir/grassIslandRegression"

"$test_dir/grassIslandRegression"
