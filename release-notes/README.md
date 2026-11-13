# Release notes

One file per release, named after its tag (`v0.3.4.md`), written with the
release PR. CI puts it on the draft release when the tag is built; people
read it on the release page and in the app's update dialog (Markdown).
No file: the draft's notes are empty, to be filled in before publishing.

Write for the people using the app: what's new and how to use it, not pull
request numbers or code.

A release built on the PC instead of CI (small changes, to save Actions
minutes) is tagged `vX.Y.Z-local`, so CI ignores it; its notes go in
`vX.Y.Z-local.md` and are put on the draft by hand. The app reads it as
version X.Y.Z (the `-local` only says where it was built).
