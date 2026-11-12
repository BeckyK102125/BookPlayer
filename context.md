# context.md - current snapshot

Date: 2026-11-12
Branch: develop (BookPlayer fork).

## Goal
Listen Together: share downloaded audiobooks, keep playback and own-copy progress in sync,
and support VoiceOver and Zoom. Resolve the existing device report and outstanding audit findings.

## Last work
- November 12: Codex with three Astra Medium reviewers rechecked all 22 October 23 findings.
- R01 (Siri PlayMedia routing) and R02 (video surface) are addressed in source.
- R03–R22 remain open: 8 P1 and 12 P2. New review is at the top of Review.md;
  IDs BP-20261112-03 through BP-20261112-22. Earlier review retained verbatim.
- Filed those 20 findings in Start Testing, project BookPlayer - Listen together (697bd58a),
  with proof steps and Safe Alone/Needs Becky. Existing temporary-copy report left unchanged.
- Earlier source fixes for upload status, Hardcover ID, completion ownership, activation crash,
  six App Intents, transfer-cover arbitration and live sharer status remain present.
- October 28 listener rejoin change is present: interruption end rejoins even without shouldResume,
  unless user Pause/route loss requires explicit Play. No new device acceptance performed.
- TestFlight 5.22.2 (6) was the last documented internal release; release status was not queried today.
- November 2 Start Testing report says own-copy listening worked, but temporary-copy sharing failed;
  stage/cause unknown. Item dd0bde92-7e20-402d-b5ab-00fa8f984a0f, Needs Becky.

## Test results
- This review: git diff 8cb29725 HEAD plus current source/caller inspection; 2 addressed, 20 open.
- Documentation validation: preservation of old review, unique IDs, local links and git diff --check.
- No builds, automated tests, TSan, Simulator or phone actions in this review.
- Historical only: merged full suite 1757/0; SharePlay + PlayerManager 736/0 with targeted TSan clean.
- Historical October 28 targeted rejoin tests 135/0. Whole-suite TSan had a DirectoryWatcher race.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
1. Reproduce the existing temporary-copy sharing failure with both phones and capture its exact stage.
2. Prioritize BP-20261112-03 through -10 (P1); read item status/comments before starting any fix.
3. Address remaining P2 findings and verify each using its proof steps; Testing awaits device acceptance.
4. Complete multi-device session-end, interruption, own-copy boundary, Siri/video and accessibility checks.
5. Plan Swift 6/Complete concurrency migration, over-700-line file splits and missing translations separately.

## Open questions and constraints
- PlayerManager.swift: Becky must approve before implementation changes (existing project constraint).
- Never commit BuildConfiguration/Debug.xcconfig. No push authorized for this audit update.
- Main worktree has an unrelated untracked .nova/ directory; leave it alone.
- Full history, design rulings and earlier device-check lists are in Notes.md.
