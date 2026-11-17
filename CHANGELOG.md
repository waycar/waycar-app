# Changelog

All notable changes to Waycar are documented here first: unreleased entries
go under [Unreleased] below. `make publish` moves them into
`apps/web/src/content/changelog/<version>.md`, one file per release, and
each release since 1.0.1 is published at waycar.dev/changelog and in
Settings › About › Changelog.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries reference the issue that motivated them.

## [Unreleased]

### Changed

- Every Console row you can hide now has the same Not now button. It replaces
  swipe to hide on the "Herdr Core is not running" row, and the ✕ on the
  "plugin is out of date" row. A "not running" row stays hidden on that Host
  until you start it from the Host's page.
