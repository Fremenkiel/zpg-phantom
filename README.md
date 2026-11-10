> [!IMPORTANT]  
> Windows is not officially supported by this lib.

Zig lib allowing for a quick inialization of a postgres database, primarily for testing purposes. 

The lib allows you to test dropouts, by killing the database process and starting a new on the same socket.

# Usage
```zig
// creates a temp folder inside the dest dir, and creates a reflink copy of the source file
var database = try Phantom.init(allocator, io, "./test/template.db", "/tmp");
// kills process if running and removes temp folder
defer database.deinit();

// starts postgres process using socket
// bolcks until postgress ready message has been received
try database.spawn();

// socket to be used as host
// i.e. psql -h {host} -U postgres
const host = database.socket_path;

// blocking until terminated
try database.kill(.TERM);

// starts new process using same data source and socket.
try database.spawn();
```

# Create db

```zsh
/opt/homebrew/opt/postgresql@18/bin/initdb -D test/template.db -U postgres --auth=trust --no-sync -E UTF8 --locale=C
```

# Deps
https://github.com/postgres/postgres.git
