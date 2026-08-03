# Identity-admin migration contract

Source: `go/controller/user.go` (`GetAllUsers`, `SearchUsers`,
`GetUser`, `CreateUser`, `UpdateUser`, `DeleteUser`, `ManageUser`) and
`model/user.go` (`GetAllUsers`, `SearchUsers`, `UpdateWithTx`).

Implemented endpoints:

- `GET /api/user/`: administrator-only, unscoped page, default page size 10,
  accepts `p`, `page_size`/`ps`/`size`, caps size at 100 and applies legacy
  sort keys.
- `GET /api/user/search`: administrator-only unscoped search across username,
  email, display name and a numeric id; supports group, role and status. A
  status of `-1` selects soft-deleted users.
- `GET|DELETE /api/user/:id`, `POST|PUT /api/user/`, `POST /api/user/manage`:
  administrator role ordering matches the legacy root-or-strictly-higher rule.

Security-sensitive mutations (password/group edit, enable/disable, promote,
demote, soft delete) increment `users.auth_version`, revoke active PostgreSQL
sessions, and write `auth:user:fence:<id>` in Valkey. This is the equivalent
of legacy auth-cache publication: existing Rust bearer sessions reject on the
next request even if their hashed session cache has not expired.

Deliberate boundary: `/api/user/groups` belongs to `controller/group.go`, not
the user-management controller; this slice does not claim it.
