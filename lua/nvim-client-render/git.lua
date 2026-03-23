local config = require("nvim-client-render.config")
local ssh = require("nvim-client-render.ssh")

local M = {}

---@class GitState
---@field project_info ProjectInfo
---@field wrapper_path string
---@field git_dir string
---@field remote_git_dir string
---@field prev_head string|nil
---@field prev_fugitive_executable string|nil
---@field prev_path string|nil

---@type GitState|nil
M._state = nil

---Shell-quote a string for safe embedding in shell scripts
---@param s string
---@return string
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Expose for testing
M._shell_quote = shell_quote

local get_ssh_dest = ssh.ssh_dest

---Check if the remote project is a git repository
---Uses `git rev-parse` to handle standard repos, worktrees, bare repos, and .git files
---@param project_info ProjectInfo
---@param callback fun(is_git: boolean, remote_git_dir: string|nil)
function M.detect(project_info, callback)
  local git_cfg = config.values.git
  if not git_cfg or not git_cfg.enabled or not git_cfg.auto_detect then
    vim.schedule(function() callback(false) end)
    return
  end

  ssh.exec(
    project_info.host,
    "cd " .. shell_quote(project_info.remote_path) .. " && git rev-parse --git-dir 2>/dev/null",
    function(code, stdout)
      if code ~= 0 or #stdout == 0 then
        callback(false)
        return
      end

      local remote_git_dir = stdout[1]
      -- Resolve relative paths (e.g. ".git" → "<remote_path>/.git")
      if not remote_git_dir:match("^/") then
        remote_git_dir = project_info.remote_path .. "/" .. remote_git_dir
      end

      callback(true, remote_git_dir)
    end
  )
end

---Create the .git shim directory structure
---@param project_info ProjectInfo
---@param callback fun(err: string|nil)
function M.create_shim(project_info, callback)
  local git_dir = project_info.local_path .. "/.git"

  vim.fn.mkdir(git_dir .. "/refs/heads", "p")
  vim.fn.mkdir(git_dir .. "/refs/remotes", "p")
  vim.fn.mkdir(git_dir .. "/refs/tags", "p")
  vim.fn.mkdir(git_dir .. "/objects", "p")

  M._state.git_dir = git_dir
  M.sync_metadata(callback)
end

---Sync git metadata (HEAD, refs, config) from remote to local shim
---Handles worktrees: HEAD/state from git-dir, config/refs from git-common-dir
---@param callback fun(err: string|nil)
function M.sync_metadata(callback)
  local state = M._state
  if not state or not state.project_info then
    vim.schedule(function() callback("Git not initialized") end)
    return
  end

  local info = state.project_info
  local git_dir = state.git_dir

  -- Use git rev-parse to find the actual git dirs (handles worktrees)
  -- git-dir: worktree-specific (HEAD, MERGE_HEAD, etc.)
  -- git-common-dir: shared (config, refs/, packed-refs)
  local tar_cmd = "cd " .. shell_quote(info.remote_path) .. " && {"
    .. ' gd=$(git rev-parse --git-dir 2>/dev/null);'
    .. ' cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "$gd");'
    .. ' sf=""; for f in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD; do'
    .. '   test -f "$gd/$f" && sf="$sf $f";'
    .. ' done;'
    .. ' pr=""; test -f "$cdir/packed-refs" && pr="packed-refs";'
    .. ' tar cf - -C "$gd" HEAD $sf -C "$cdir" config refs/ $pr 2>/dev/null;'
    .. " } || true"

  local ssh_args, parsed = ssh.get_ssh_args(info.host)
  if not ssh_args or not parsed then
    vim.schedule(function() callback("Not connected") end)
    return
  end

  local dest = get_ssh_dest(parsed)
  local ssh_parts = { "ssh" }
  for _, a in ipairs(ssh_args) do
    table.insert(ssh_parts, vim.fn.shellescape(a))
  end
  table.insert(ssh_parts, vim.fn.shellescape(dest))
  table.insert(ssh_parts, "--")
  table.insert(ssh_parts, vim.fn.shellescape(tar_cmd))

  local cmd = table.concat(ssh_parts, " ")
    .. " | tar xf - -C " .. vim.fn.shellescape(git_dir) .. " 2>/dev/null; true"

  vim.fn.jobstart({ "sh", "-c", cmd }, {
    on_exit = function()
      vim.schedule(function()
        if vim.fn.filereadable(git_dir .. "/HEAD") == 1 then
          local head = vim.fn.readfile(git_dir .. "/HEAD")
          if head and #head > 0 then
            state.prev_head = state.prev_head or head[1]
          end
          callback(nil)
        else
          callback("Failed to sync git metadata: HEAD not found")
        end
      end)
    end,
  })
end

---Generate the git wrapper script
---@param project_info ProjectInfo
---@return string wrapper_path
function M.create_wrapper(project_info)
  local ssh_args, parsed = ssh.get_ssh_args(project_info.host)
  if not ssh_args or not parsed then
    error("Not connected to " .. project_info.host)
  end

  local dest = get_ssh_dest(parsed)
  local control_dir = config.values.ssh.control_dir
  local git_dir = project_info.local_path .. "/.git"
  -- Use the actual remote git dir detected by detect() (handles worktrees/bare repos)
  local remote_git_dir = (M._state and M._state.remote_git_dir)
    or (project_info.remote_path .. "/.git")

  -- Extract socket path from SSH args
  local socket = ""
  for i, a in ipairs(ssh_args) do
    if a == "-S" and ssh_args[i + 1] then
      socket = ssh_args[i + 1]
      break
    end
  end

  local port_args = parsed.port and ("-p " .. parsed.port) or ""
  local real_git = vim.fn.exepath("git")
  if real_git == "" then real_git = "git" end

  -- rsync -e value for editor bridge file transfers
  local rsync_ssh = "ssh -S " .. socket
  if port_args ~= "" then
    rsync_ssh = rsync_ssh .. " " .. port_args
  end

  -- Place wrapper as "git" in a bin dir so uv.spawn("git") finds it
  local bin_dir = control_dir .. "/bin"
  vim.fn.mkdir(bin_dir, "p")
  local wrapper_path = bin_dir .. "/git"

  -- Build wrapper script line-by-line
  local lines = {}
  local function add(line)
    table.insert(lines, line)
  end

  add("#!/bin/sh")
  add("# nvim-client-render: git wrapper for remote proxy")
  add("# Project: " .. project_info.name)
  add("")
  add("LOCAL_ROOT=" .. shell_quote(project_info.local_path))
  add("REMOTE_ROOT=" .. shell_quote(project_info.remote_path))
  add("LOCAL_GIT_DIR=" .. shell_quote(git_dir))
  add("REMOTE_GIT_DIR=" .. shell_quote(remote_git_dir))
  add("SSH_SOCKET=" .. shell_quote(socket))
  add("SSH_DEST=" .. shell_quote(dest))
  add("SSH_PORT_ARGS=" .. shell_quote(port_args))
  add("REAL_GIT=" .. shell_quote(real_git))
  add("RSYNC_SSH=" .. shell_quote(rsync_ssh))
  add("")

  -- sq() function: outputs its argument wrapped in properly-escaped single quotes
  -- In the file this line is literal (no Lua escape processing in [[ ]]):
  --   sed "s/'/'\\''/g"  →  shell double-quotes: \\ → \  →  sed sees: s/'/'\''/g
  add([[sq() { printf "'"; printf '%s' "$1" | sed "s/'/'\\''/g"; printf "'"; }]])
  add("")

  -- Detect whether this invocation targets our remote project
  -- Three detection methods: --git-dir= args, -C args, or CWD
  add("is_remote=false")
  add("has_git_dir_arg=false")
  add("has_C_arg=false")
  add("check_C_next=false")
  add('for arg in "$@"; do')
  add('  if [ "$check_C_next" = "true" ]; then')
  add('    check_C_next=false')
  add('    case "$arg" in')
  add('      "$LOCAL_ROOT"|"$LOCAL_ROOT"/*)')
  add('        is_remote=true; has_C_arg=true ;;')
  add('    esac')
  add('    continue')
  add('  fi')
  add('  case "$arg" in')
  add('    --git-dir="$LOCAL_GIT_DIR"|--git-dir="$LOCAL_GIT_DIR"/*)')
  add('      is_remote=true; has_git_dir_arg=true ;;')
  add('    -C)')
  add('      check_C_next=true ;;')
  add('  esac')
  add('done')
  add('')
  add('# Also detect via CWD being inside the local mirror')
  add('remote_cwd=""')
  add('if [ "$is_remote" = "false" ]; then')
  add('  cwd=$(pwd)')
  add('  case "$cwd" in')
  add('    "$LOCAL_ROOT")')
  add('      is_remote=true')
  add('      remote_cwd="$REMOTE_ROOT" ;;')
  add('    "$LOCAL_ROOT"/*)')
  add('      is_remote=true')
  add('      remote_cwd="${REMOTE_ROOT}${cwd#$LOCAL_ROOT}" ;;')
  add('  esac')
  add('fi')
  add('')
  add('if [ "$is_remote" = "false" ]; then')
  add('  exec "$REAL_GIT" "$@"')
  add('fi')
  add('')

  -- Rewrite args: local paths → remote paths
  -- Also detect local temp files that need to be transferred to remote
  add("rewritten=''")
  add("skip_next=false")
  add("past_dd=false")
  add("temp_files=''")
  add("")
  add('for arg in "$@"; do')
  add('  if [ "$skip_next" = "true" ]; then')
  add('    skip_next=false')
  add('    case "$arg" in')
  add('      "$LOCAL_ROOT"|"$LOCAL_ROOT"/*)')
  add('        arg="${REMOTE_ROOT}${arg#$LOCAL_ROOT}" ;;')
  add('    esac')
  add('    rewritten="$rewritten $(sq "$arg")"')
  add('    continue')
  add('  fi')
  add('  case "$arg" in')
  add('    --)')
  add('      past_dd=true')
  add('      rewritten="$rewritten --" ;;')
  add('    --git-dir="$LOCAL_GIT_DIR"*)')
  add('      suffix="${arg#--git-dir=$LOCAL_GIT_DIR}"')
  add('      rewritten="$rewritten $(sq "--git-dir=${REMOTE_GIT_DIR}${suffix}")" ;;')
  add('    -C)')
  add('      rewritten="$rewritten -C"')
  add('      skip_next=true ;;')
  add('    *)')
  add('      if [ "$past_dd" = "true" ]; then')
  add('        case "$arg" in')
  add('          "$LOCAL_ROOT"/*)')
  add('            arg="${REMOTE_ROOT}${arg#$LOCAL_ROOT}" ;;')
  add('        esac')
  add('      fi')
  add('      # Detect local temp files (e.g. fugitive patch files)')
  add('      case "$arg" in')
  add('        /tmp/*|/var/tmp/*)')
  add('          if [ -f "$arg" ]; then')
  add('            temp_files="$temp_files $arg"')
  add('          fi ;;')
  add('      esac')
  add('      rewritten="$rewritten $(sq "$arg")" ;;')
  add('  esac')
  add('done')
  add('')
  add('# If detected via CWD and no -C was in the args, prepend -C <remote_cwd>')
  add('if [ -n "$remote_cwd" ] && [ "$has_C_arg" = "false" ]; then')
  add('  rewritten="-C $(sq "$remote_cwd") $rewritten"')
  add('fi')
  add('')

  -- Editor coordination protocol:
  -- 1. Deploy a small script to remote that signals when git needs an editor
  -- 2. Run git in background
  -- 3. Poll for signal, download file, run local editor, upload, signal done
  -- Skip editor coordination when GIT_EDITOR is "true" — fugitive sets this
  -- to suppress editors on read-only commands (log, diff, etc.)
  add('_need_editor=false')
  add('case "${GIT_EDITOR:-}" in ""|true|/usr/bin/true|/bin/true) ;; *) _need_editor=true ;; esac')
  add('case "${GIT_SEQUENCE_EDITOR:-}" in ""|true|/usr/bin/true|/bin/true) ;; *) _need_editor=true ;; esac')
  add('if [ "$_need_editor" = "true" ]; then')
  add('  orig_editor="${GIT_EDITOR:-$GIT_SEQUENCE_EDITOR}"')
  add('  coord_id="nvim_$$_$(date +%s)"')
  add('  signal_file="/tmp/.${coord_id}_signal"')
  add('  done_file="/tmp/.${coord_id}_done"')
  add('  coord_script="/tmp/.${coord_id}_editor.sh"')
  add('')
  add('  # Deploy coordination editor script to remote')
  add('  ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" \\')
  add('    "cat > \'$coord_script\' && chmod +x \'$coord_script\'" <<NVIM_EDITOR_EOF')
  -- Heredoc content: \$ prevents expansion so $1/$0 stay literal in deployed script
  -- $signal_file and $done_file ARE expanded (they are wrapper-local variables)
  add('#!/bin/sh')
  add('echo "\\$1" > "$signal_file"')
  add('while [ ! -f "$done_file" ]; do sleep 0.1; done')
  add('rm -f "$signal_file" "$done_file" "\\$0"')
  add('NVIM_EDITOR_EOF')
  add('')
  add('  editor_env="GIT_EDITOR=\'$coord_script\' GIT_SEQUENCE_EDITOR=\'$coord_script\'"')
  add('  ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" -- "$editor_env git $rewritten" &')
  add('  ssh_pid=$!')
  add('')
  add('  # Poll for editor signal')
  add('  while true; do')
  add('    if ! kill -0 $ssh_pid 2>/dev/null; then')
  add('      wait $ssh_pid; exit $?')
  add('    fi')
  add('    remote_file=$(ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" "cat \'$signal_file\' 2>/dev/null" 2>/dev/null)')
  add('    if [ -n "$remote_file" ]; then break; fi')
  add('    sleep 0.2')
  add('  done')
  add('')
  add('  # Download edit file from remote')
  add('  local_basename=$(basename "$remote_file")')
  add('  local_file="$LOCAL_GIT_DIR/$local_basename"')
  add('  rsync -az -e "$RSYNC_SSH" "$SSH_DEST:$remote_file" "$local_file" 2>/dev/null')
  add('')
  add('  # Run original local editor (e.g. fugitive\'s editor script)')
  add('  eval "$orig_editor" "\\"$local_file\\""')
  add('  editor_exit=$?')
  add('')
  add('  # Upload edited file back to remote')
  add('  rsync -az -e "$RSYNC_SSH" "$local_file" "$SSH_DEST:$remote_file" 2>/dev/null')
  add('')
  add('  # Signal remote coordination script to continue')
  add('  ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" "touch \'$done_file\'"')
  add('')
  add('  wait $ssh_pid')
  add('  exit $?')
  add('fi')
  add('')

  -- Transfer any local temp files to remote before executing
  add('if [ -n "$temp_files" ]; then')
  add('  for tf in $temp_files; do')
  add('    tf_dir=$(dirname "$tf")')
  add('    ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" "mkdir -p \'$tf_dir\'" 2>/dev/null')
  add('    rsync -az -e "$RSYNC_SSH" "$tf" "$SSH_DEST:$tf" 2>/dev/null')
  add('  done')
  add('  ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" -- "git $rewritten"')
  add('  git_exit=$?')
  add('  for tf in $temp_files; do')
  add('    ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" "rm -f \'$tf\'" 2>/dev/null')
  add('  done')
  add('  exit $git_exit')
  add('fi')
  add('')
  -- Simple proxy (no editor, no temp files): exec for proper signal propagation
  add('exec ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" -- "git $rewritten"')
  add("")

  vim.fn.writefile(lines, wrapper_path)
  vim.fn.setfperm(wrapper_path, "rwx------")

  return wrapper_path
end

---Configure fugitive to use the wrapper script
---@param wrapper_path string
function M.configure_fugitive(wrapper_path)
  local state = M._state
  state.prev_fugitive_executable = vim.g.fugitive_git_executable

  vim.g.fugitive_git_executable = wrapper_path

  -- Trigger fugitive detection on the local mirror
  if vim.fn.exists("*FugitiveDetect") == 1 then
    vim.fn.FugitiveDetect(state.project_info.local_path)
  end
end

---Full setup: detect → shim → wrapper → fugitive config
---@param project_info ProjectInfo
---@param callback fun(err: string|nil)
function M.setup(project_info, callback)
  local git_cfg = config.values.git
  if not git_cfg or not git_cfg.enabled then
    vim.schedule(function() callback(nil) end)
    return
  end

  M.detect(project_info, function(is_git, remote_git_dir)
    if not is_git then
      callback("Not a git repository")
      return
    end

    M._state = { project_info = project_info, remote_git_dir = remote_git_dir }

    M.create_shim(project_info, function(shim_err)
      if shim_err then
        M._state = nil
        callback(shim_err)
        return
      end

      vim.schedule(function()
        local ok, result = pcall(M.create_wrapper, project_info)
        if not ok then
          M._state = nil
          callback("Wrapper creation failed: " .. tostring(result))
          return
        end

        M._state.wrapper_path = result

        -- Prepend wrapper's bin dir to PATH so uv.spawn("git") finds it
        local bin_dir = vim.fn.fnamemodify(result, ":h")
        M._state.prev_path = vim.env.PATH
        vim.env.PATH = bin_dir .. ":" .. vim.env.PATH

        if git_cfg.fugitive then
          M.configure_fugitive(result)
        end

        vim.notify("[nvim-client-render] Git integration active", vim.log.levels.INFO)
        callback(nil)
      end)
    end)
  end)
end

---Clean up git integration
function M.teardown()
  local state = M._state
  if not state then return end

  -- Restore PATH
  if state.prev_path then
    vim.env.PATH = state.prev_path
  end

  -- Restore previous fugitive executable
  if state.prev_fugitive_executable ~= nil then
    vim.g.fugitive_git_executable = state.prev_fugitive_executable
  elseif state.wrapper_path then
    pcall(vim.api.nvim_del_var, "fugitive_git_executable")
  end

  -- Clean up wrapper script and bin dir
  if state.wrapper_path then
    local bin_dir = vim.fn.fnamemodify(state.wrapper_path, ":h")
    if vim.fn.filereadable(state.wrapper_path) == 1 then
      vim.fn.delete(state.wrapper_path)
    end
    pcall(vim.fn.delete, bin_dir, "d")
  end

  M._state = nil
end

---Handle FugitiveChanged autocmd — re-sync metadata and detect branch changes
function M.on_fugitive_changed()
  local state = M._state
  if not state or not state.project_info then return end

  M.sync_metadata(function(err)
    if err then return end
    if not state.git_dir then return end

    local head = vim.fn.readfile(state.git_dir .. "/HEAD")
    if not head or #head == 0 then return end

    local current_head = head[1]
    if state.prev_head and current_head ~= state.prev_head then
      state.prev_head = current_head

      -- Branch changed — resync project files
      if config.values.git.resync_on_branch_change then
        local project = require("nvim-client-render.project")
        project.refresh()
      end
    else
      state.prev_head = current_head
    end
  end)
end

---Run an arbitrary git command on the remote and return output
---@param args string
---@param callback fun(code: number, stdout: string[], stderr: string[])
function M.exec(args, callback)
  local state = M._state
  if not state or not state.project_info then
    vim.schedule(function() callback(1, {}, { "Git not initialized" }) end)
    return
  end

  local info = state.project_info
  local cmd = "cd " .. shell_quote(info.remote_path) .. " && git " .. args
  ssh.exec(info.host, cmd, callback)
end

return M
