
# Usage
```zig
var database = try Phantom.init(allocator, io, "./test/template.db", "/tmp");
defer database.deinit();

// Socket to be used as host
// i.e. psql -h {host} -U postgres
const host = try database.spawnProcess();
try database.waitUntilReady();
```

# Create db

```zsh
/opt/homebrew/opt/postgresql@18/bin/initdb -D test/template.db -U postgres --auth=trust --no-sync -E UTF8 --locale=C
```
