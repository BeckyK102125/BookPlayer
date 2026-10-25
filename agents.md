# BookPlayer fork: reviews and audits

Rules for everyone who reviews or audits this fork: Codex, Claude, Aquila
(Grok bot, also called Swift Dev) or any other reviewer. Architecture, build
rules and the reviewer hotlist are in `CLAUDE.md`; the severity rubric is in
`.github/claude/review-guide.md`.

1. Every code review and audit goes in one file: `review.md` in the
   repository root of the main checkout on Becky's main Mac,
   `/Users/becky/Developer/Swift/BookPlayer/review.md`. Do not create another
   review file, and do not leave a review only in a chat or in a copy of the
   repository on another machine.
   - `review.md` is never committed or pushed. The fork on GitHub
     (BeckyK102125/BookPlayer) is public, so the file stays local and is
     listed in `.git/info/exclude`.
   - Put the new review at the top of the file, above every earlier review.
     Never delete or rewrite earlier reviews.
   - Start it with a level-1 heading naming the reviewer, what was reviewed
     and the date, for example
     `# Aquila (Grok): develop audit — October 25, 2026`.
   - Under it, give the branch, the full commit hash reviewed, and the
     checkout path or GitHub repository you read.
   - Number every finding with a prefix unique to that reviewer (Aquila uses
     `BP-`, continuing from its last number: BP-01, BP-02 and so on), with
     its severity, file and line, and a short failure scenario, so fixes can
     refer to it. Severity: Critical, P1 (High), P2 (Medium), P3 (Low:
     polish and hardening, not release blocking).
   - Mark anything that needs Xcode, Instruments or a device to confirm as
     Unverified.
   - If you work on another machine and cannot write to that path, do not
     push a review branch. Put the review in the hand-off folder (rule 2) as
     its own file, and Claude copies it to the top of `review.md`.
   - Never push to `develop`, `main` or any other branch yourself.

2. Hand-offs between Claude and Aquila go in
   `/Users/becky/Developer/Swift/swift-dev-review/BookPlayer/HANDOFF.md` on
   Becky's main Mac. Aquila copies files into that folder with Becky's
   permission. Newest entry first in the "To Aquila" or "To Claude" section,
   with the date, the writer, the branch and the full commit. Never delete
   someone else's entry. Reviews themselves still end up in `review.md`
   (rule 1).

3. When a review arrives, Claude copies it to the top of `review.md`, checks
   every finding against the code, and answers in `HANDOFF.md` with what is
   confirmed, partly fixed, not a bug (with the reason) or left for Becky's
   decision. Fixes refer to the finding numbers in their commit messages and
   in `Notes.md`, and each fix comes with a test where one is possible
   (XCTest, as `CLAUDE.md` says).

4. Aquila reads code from GitHub, so it can only audit commits that are
   pushed. Branches that exist only on Becky's Macs are out of its reach
   until Becky pushes them.
