# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

### Fixed

### Changed
- UI: Implement visible focus states for keyboard navigation (#49)
- UI: Add ARIA labels and states for accessibility (#44)
- Investigate potential memory growth in monitors (#40)
- Add rate limiting to external API calls (#33)
- Standardize error handling across client modules (#30)
- Use Task.Supervisor.start_child consistently (#29)
- Add input validation to handle_event handlers (#27)
- Add missing tests for monitor modules (#26)
- Extract duplicated process parsing logic (#25)
- Memoize build_agent_activity and build_graph_data (#6)
- Use phx-update=stream for Live Feed (#5)
- Pre-calculate derived data instead of computing in templates (#3)
- Refactor HomeLive god module (3000+ lines) (#21)
- Reduce SessionBridge polling frequency (#24)
- Remove hardcoded paths throughout codebase (#19)
- Fix race conditions in file operations (#22)
- Add timeouts to all external CLI calls (#23)
- Add authentication to dashboard (#20)
- Re-add Chainlink panel after template extraction merge (#43)
- Add Chainlink issues panel with Work button (#17)
- Move inline template to separate .html.heex file (#2)
- Make Fix button responsive and show tap state (#18)
- Add Chainlink issues panel with Work button (#17)
- Show PR verification status in panel (#15)
- PR background colors reflect status (#16)
- Add Dave panel for main agent (#14)
- Add agent work indicator to PR panel (#13)
- Refactor home_live.ex into LiveComponents (#1)
- Enhance Sub-Agents panel with richer info (#11)
- Add Gemini agents to relationship diagram (#12)
- Add Task.Supervisor for async loading tasks (#7)
- Pre-calculate linear_counts to avoid 4x iteration per render (#4)
