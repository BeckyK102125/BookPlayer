# BookPlayer fork: reviews and audits

These are the same review rules as Start Speaking (its agents.md rules 9 and
10). Architecture, build rules and the reviewer hotlist are in `CLAUDE.md`;
the severity rubric is in `.github/claude/review-guide.md`.

1. Code reviews and audits (Codex, Claude, Aquila or any other reviewer)
   go in one file: `Review.md` in the repository root of the main checkout
   on Becky's main Mac, `/Users/becky/Developer/Swift/BookPlayer/Review.md`
   (branch `develop`). Do not create another review file, and do not write
   the review only into a chat or a copy of the repository on another
   machine.
   - Put the new review at the top of the file, above every earlier review.
     Never delete or rewrite earlier reviews.
   - Start it with a level-1 heading naming the reviewer, what was reviewed
     and the date, for example
     `# Aquila (Grok): develop audit — October 25, 2026`.
   - Under it, give the branch, the full commit hash reviewed, and the
     checkout path you read.
   - Number every finding with a prefix unique to that review (for example
     `BP-01`), with its severity, file and line, and a short failure
     scenario, so fixes can refer to it.
   - If you work on another machine and cannot write to that path, commit
     the review to `Review.md` on a branch named
     `review/<reviewer>-<yyyy-mm-dd>`, push it to GitHub, and tell Becky the
     branch name. Never push to `develop` or `main` yourself.

2. Hand-offs between Claude and Grok bot (Swift Dev, through Aquila) go in
   `/Users/becky/Developer/Swift/swift-dev-review/BookPlayer/HANDOFF.md` on
   Becky's main Mac. Grok bot copies files into that folder with Becky's
   permission. Newest entry first in the "To Grok bot" or "To Claude"
   section, with the date, the writer, the branch and the full commit.
   Never delete someone else's entry. Reviews themselves still go in
   Review.md (rule 1).
