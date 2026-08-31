# LetsMove (vendored)

`PFMoveApplication.{h,m}` from https://github.com/potionfactory/LetsMove
(version 1.25, public domain). Offers to move the app to /Applications on
first run and relaunches from there.

Vendored rather than pulled as a dependency so the exact source that ships
is auditable in-tree. Relaunch uses `/bin/sh` but shell-quotes the path via
`ShellQuotedString` (single-quote + `'\''` escaping), and a colliding
destination is moved to the Trash (recoverable), not deleted.

Compiled with `-fno-objc-arc` (the source is manual-retain/release) and
linked against the Security framework (AuthorizationExecuteWithPrivileges
for the admin-authorized install path).
