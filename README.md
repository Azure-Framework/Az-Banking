# Az-Banking

This standalone resource has been merged into Az-Framework 2.0.

Use `Az-Framework/modules/banking` through the main `Az-Framework` resource instead of installing this repository as a separate FiveM resource.

## Migration

1. Remove `ensure Az-Banking` from `server.cfg`.
2. Make sure `ensure Az-Framework` starts after `oxmysql` and `ox_lib`.
3. Update exports/events to use `exports['Az-Framework']` where applicable.
4. Keep this repository as a migration notice only.
