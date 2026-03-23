# nvim-client-render

> **Disclaimer:** This plugin was completely vibe coded. It works for me, so I'm going to use it. It is purely functional and not representative of my work if I do put in the effort.

Remote development in Neovim — edit files on a remote server locally with two-way file sync, git integration, remote LSP, and remote terminals.

## Features

- **Remote file editing** — open a remote project and edit files locally with automatic sync
- **Two-way sync** — local saves upload instantly; remote changes download automatically via `inotifywait`/`fswatch`
- **Remote LSP** — run language servers on the remote host with transparent URI rewriting
- **Remote terminal** — SSH shell with auto-cd into the project directory (horizontal, vertical, or floating split)
- **Git integration** — run git commands remotely, sync metadata locally, optional fugitive support
- **Multi-session** — work on multiple remote projects simultaneously
- **Interactive browser** — browse and select remote directories before opening

## Requirements

- **Neovim >= 0.10**
- **ssh** with ControlMaster support
- **rsync**
- **git** (optional, for git features)
- **inotifywait** or **fswatch** on the remote host (optional, for remote file watching)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "rohansjamadagni/nvim-client-render",
  cmd = {
    "RemoteOpen",
    "RemoteClose",
    "RemoteStatus",
    "RemoteSync",
    "RemoteBrowse",
    "RemoteTerminal",
    "RemoteWatch",
    "RemoteLsp",
    "RemoteGit",
    "RemoteSession",
  },
  opts = {
    -- override any defaults here (see Configuration below)
  },
}
```

## Configuration

All options and their defaults:

```lua
require("nvim-client-render").setup({
  ssh = {
    control_persist = "10m",
    connect_timeout = 10,
    server_alive_interval = 15,
  },
  transfer = {
    rsync_flags = { "-az", "--inplace", "--partial" },
    exclude = { ".git", "node_modules", "__pycache__", ".venv", "target", "build" },
  },
  sync = {
    debounce_ms = 300,
    retry_interval_ms = 5000,
    max_retries = 10,
  },
  project = {
    auto_cd = true,
  },
  remote_watcher = {
    enabled = true,
    debounce_ms = 500,
    suppress_ttl_ms = 5000,
    conflict_strategy = "warn", -- "warn" | "local_wins" | "remote_wins"
  },
  terminal = {
    default_split = "vertical",
    float_width = 0.8,
    float_height = 0.8,
    auto_cd = true,
  },
  lsp = {
    enabled = true,
    auto_start = true,
    servers = {},
  },
  git = {
    enabled = true,
    auto_detect = true,
    fugitive = true,
    resync_on_branch_change = true,
  },
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:RemoteOpen <host> <path>` | Open a remote project |
| `:RemoteClose` | Close the active remote project |
| `:RemoteStatus` | Show sync queue, connection, and LSP status |
| `:RemoteSync [git\|retry]` | Re-sync from remote or retry failed uploads |
| `:RemoteBrowse <host> [path]` | Browse remote directories interactively |
| `:RemoteTerminal [split]` | Open a remote shell (`horizontal`, `vertical`, `float`, `close`) |
| `:RemoteWatch` | Toggle remote filesystem watcher |
| `:RemoteLsp [start\|stop\|restart\|status] [cmd]` | Manage remote LSP servers |
| `:RemoteGit [args]` | Run git commands on the remote host |
| `:RemoteSession [list\|switch]` | Manage multiple remote sessions |

## Usage

```vim
" Open a remote project
:RemoteOpen myserver ~/projects/myapp

" Browse and pick a directory
:RemoteBrowse myserver

" Open a remote terminal
:RemoteTerminal float

" Check status
:RemoteStatus

" Run remote git commands
:RemoteGit status
:RemoteGit pull

" Start/restart a remote LSP
:RemoteLsp restart
```

## Health Check

Run `:checkhealth nvim-client-render` to verify that all system dependencies are available and connections are working.

## License

MIT
