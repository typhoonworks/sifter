# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added
- Support for NULL values in equality operations (e.g., `organization_id:NULL`)
- Support for NULL values in IN/NOT IN operations (e.g., `organization_id IN (NULL, 123, 456)`)

### Fixed
- Rewrote builder to properly support IN operations with associations in complex conditions (OR/AND)
- Fixed contains_all operations with association fields

## [0.1.0] - 2025-08-19
- Initial implementation of Sifter library
