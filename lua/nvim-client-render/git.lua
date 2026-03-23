local config = require("nvim-client-render.config")
local ssh = require("nvim-client-render.ssh")

local M = {}

---@class GitSession
---@field project_info ProjectInfo
---@field git_dir string
---@field remote_git_dir string
---@field prev_head string|nil

---@type table<string, GitSession>
M._sessions = {}

---@type string|nil  saved once when first session added
M._original_path = nil

---@type string|nil  saved once when first session added
M._original_fugitive = nil

---@type string|nil  single dispatcher script path
M._wrapper_path = nil

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
      if not remote_git_dir:match("^/") then
        remote_git_dir = project_info.remote_path .. "/" .. remote_git_dir
      end

      callback(true, remote_git_dir)
    end
  )
end

---Create the .git shim directory structure for a session
---@param project_info ProjectInfo
---@param session GitSession
---@param callback fun(err: string|nil)
function M.create_shim(project_info, session, callback)
  local git_dir = project_info.local_path .. "/.git"

  vim.fn.mkdir(git_dir .. "/refs/heads", "p")
  vim.fn.mkdir(git_dir .. "/refs/remotes", "p")
  vim.fn.mkdir(git_dir .. "/refs/tags", "p")
  vim.fn.mkdir(git_dir .. "/objects", "p")

  session.git_dir = git_dir

  -- Update manifest with git_dir
  M._write_manifest(project_info.local_path, session)

  M.sync_metadata(project_info.local_path, callback)
end

---Sync git metadata (HEAD, refs, config) from remote to local shim
---@param local_path string|nil  session key, defaults to active session
---@param callback fun(err: string|nil)
function M.sync_metadata(local_path, callback)
  -- Support old signature: sync_metadata(callback)
  if type(local_path) == "function" then
    callback = local_path
    local_path = nil
  end

  local session
  if local_path then
    session = M._sessions[local_path]
  else
    -- Find first session
    for _, s in pairs(M._sessions) do
      session = s
      break
    end
  end

  if not session or not session.project_info then
    vim.schedule(function() callback("Git not initialized") end)
    return
  end

  local info = session.project_info
  local git_dir = session.git_dir

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
            session.prev_head = session.prev_head or head[1]
          end
          callback(nil)
        else
          callback("Failed to sync git metadata: HEAD not found")
        end
      end)
    end,
  })
end

---Get manifest file path for a session
---@param local_path string
---@return string
function M._get_manifest_path(local_path)
  local control_dir = config.values.ssh.control_dir
  return control_dir .. "/sessions/" .. vim.fn.sha256(local_path):sub(1, 16) .. ".json"
end

---Write session manifest to disk
---@param local_path string
---@param session GitSession
function M._write_manifest(local_path, session)
  local manifest_path = M._get_manifest_path(local_path)
  vim.fn.mkdir(vim.fn.fnamemodify(manifest_path, ":h"), "p")

  local manifest = {
    local_path = local_path,
    host = session.project_info.host,
    remote_path = session.project_info.remote_path,
    name = session.project_info.name,
    git_dir = session.git_dir,
    remote_git_dir = session.remote_git_dir,
  }

  local json = vim.json.encode(manifest)
  vim.fn.writefile({ json }, manifest_path)
end

---Delete session manifest from disk
---@param local_path string
function M._delete_manifest(local_path)
  local manifest_path = M._get_manifest_path(local_path)
  if vim.fn.filereadable(manifest_path) == 1 then
    vim.fn.delete(manifest_path)
  end
end

---Load all session manifests from disk
---@return table<string, table>  local_path -> session data
function M._load_all_manifests()
  local manifest_dir = config.values.ssh.control_dir .. "/sessions"
  if vim.fn.isdirectory(manifest_dir) == 0 then
    return {}
  end

  local sessions = {}
  local manifest_files = vim.fn.glob(manifest_dir .. "/*.json", false, true)
  if type(manifest_files) == "string" then
    manifest_files = { manifest_files }
  end

  for _, manifest_file in ipairs(manifest_files) do
    if vim.fn.filereadable(manifest_file) == 1 then
      local content = vim.fn.readfile(manifest_file)
      if #content > 0 then
        local ok, manifest = pcall(vim.json.decode, content[1])
        if ok and manifest.local_path then
          sessions[manifest.local_path] = manifest
        end
      end
    end
  end

  return sessions
end

---Regenerate the single dispatcher wrapper script covering all sessions
function M._regenerate_wrapper()
  -- Load all sessions from manifests (both this instance and others)
  local all_sessions = M._load_all_manifests()

  if vim.tbl_count(all_sessions) == 0 then
    -- No sessions left: delete wrapper, restore PATH and fugitive
    if M._wrapper_path then
      local bin_dir = vim.fn.fnamemodify(M._wrapper_path, ":h")
      if vim.fn.filereadable(M._wrapper_path) == 1 then
        vim.fn.delete(M._wrapper_path)
      end
      pcall(vim.fn.delete, bin_dir, "d")
      M._wrapper_path = nil
    end

    if M._original_path then
      vim.env.PATH = M._original_path
      M._original_path = nil
    end

    if M._original_fugitive ~= nil then
      vim.g.fugitive_git_executable = M._original_fugitive
      M._original_fugitive = nil
    else
      pcall(vim.api.nvim_del_var, "fugitive_git_executable")
    end
    return
  end

  local real_git = vim.fn.exepath("git")
  -- If the exepath points to our own wrapper, use the saved original PATH to find real git
  if M._wrapper_path and real_git == M._wrapper_path then
    if M._original_path then
      local saved = vim.env.PATH
      vim.env.PATH = M._original_path
      real_git = vim.fn.exepath("git")
      vim.env.PATH = saved
    end
  end
  if real_git == "" then real_git = "git" end

  local control_dir = config.values.ssh.control_dir
  local bin_dir = control_dir .. "/bin"
  vim.fn.mkdir(bin_dir, "p")
  local wrapper_path = bin_dir .. "/git"

  local lines = {}
  local function add(line) table.insert(lines, line) end

  add("#!/bin/sh")
  add("# nvim-client-render: git dispatcher wrapper for multi-session remote proxy")
  add("")
  add("REAL_GIT=" .. shell_quote(real_git))
  add("")

  -- sq() function
  add([[sq() { printf "'"; printf '%s' "$1" | sed "s/'/'\\''/g"; printf "'"; }]])
  add("")

  -- Shared rewrite+proxy function
  add("_rewrite_and_proxy() {")
  add("  # Rewrite args: local paths -> remote paths")
  add("  rewritten=''")
  add("  skip_next=false")
  add("  past_dd=false")
  add("  temp_files=''")
  add("")
  add('  for arg in "$@"; do')
  add('    if [ "$skip_next" = "true" ]; then')
  add('      skip_next=false')
  add('      case "$arg" in')
  add('        "$LOCAL_ROOT"|"$LOCAL_ROOT"/*)')
  add('          arg="${REMOTE_ROOT}${arg#$LOCAL_ROOT}" ;;')
  add('      esac')
  add('      rewritten="$rewritten $(sq "$arg")"')
  add('      continue')
  add('    fi')
  add('    case "$arg" in')
  add('      --)')
  add('        past_dd=true')
  add('        rewritten="$rewritten --" ;;')
  add('      --git-dir="$LOCAL_GIT_DIR"*)')
  add('        suffix="${arg#--git-dir=$LOCAL_GIT_DIR}"')
  add('        rewritten="$rewritten $(sq "--git-dir=${REMOTE_GIT_DIR}${suffix}")" ;;')
  add('      -C)')
  add('        rewritten="$rewritten -C"')
  add('        skip_next=true ;;')
  add('      *)')
  add('        if [ "$past_dd" = "true" ]; then')
  add('          case "$arg" in')
  add('            "$LOCAL_ROOT"/*)')
  add('              arg="${REMOTE_ROOT}${arg#$LOCAL_ROOT}" ;;')
  add('          esac')
  add('        fi')
  add('        # Detect local temp files (e.g. fugitive patch files)')
  add('        case "$arg" in')
  add('          /tmp/*|/var/tmp/*)')
  add('            if [ -f "$arg" ]; then')
  add('              temp_files="$temp_files $arg"')
  add('            fi ;;')
  add('        esac')
  add('        rewritten="$rewritten $(sq "$arg")" ;;')
  add('    esac')
  add('  done')
  add('')
  add('  # If detected via CWD and no -C was in the args, prepend -C <remote_cwd>')
  add('  if [ -n "$remote_cwd" ] && [ "$has_C_arg" = "false" ]; then')
  add('    rewritten="-C $(sq "$remote_cwd") $rewritten"')
  add('  fi')
  add('')

  -- Editor coordination
  add('  _need_editor=false')
  add('  case "${GIT_EDITOR:-}" in ""|true|/usr/bin/true|/bin/true) ;; *) _need_editor=true ;; esac')
  add('  case "${GIT_SEQUENCE_EDITOR:-}" in ""|true|/usr/bin/true|/bin/true) ;; *) _need_editor=true ;; esac')
  add('  if [ "$_need_editor" = "true" ]; then')
  add('    orig_editor="${GIT_EDITOR:-$GIT_SEQUENCE_EDITOR}"')
  add('    coord_id="nvim_$$_$(date +%s)"')
  add('    signal_file="/tmp/.${coord_id}_signal"')
  add('    done_file="/tmp/.${coord_id}_done"')
  add('    coord_script="/tmp/.${coord_id}_editor.sh"')
  add('')
  add('    ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" \\')
  add('      "cat > \'$coord_script\' && chmod +x \'$coord_script\'" <<NVIM_EDITOR_EOF')
  add('#!/bin/sh')
  add('echo "\\$1" > "$signal_file"')
  add('while [ ! -f "$done_file" ]; do sleep 0.1; done')
  add('rm -f "$signal_file" "$done_file" "\\$0"')
  add('NVIM_EDITOR_EOF')
  add('')
  add('    editor_env="GIT_EDITOR=\'$coord_script\' GIT_SEQUENCE_EDITOR=\'$coord_script\'"')
  add('    ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" -- "$editor_env git $rewritten" &')
  add('    ssh_pid=$!')
  add('')
  add('    while true; do')
  add('      if ! kill -0 $ssh_pid 2>/dev/null; then')
  add('        wait $ssh_pid; exit $?')
  add('      fi')
  add('      remote_file=$(ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" "cat \'$signal_file\' 2>/dev/null" 2>/dev/null)')
  add('      if [ -n "$remote_file" ]; then break; fi')
  add('      sleep 0.2')
  add('    done')
  add('')
  add('    local_basename=$(basename "$remote_file")')
  add('    local_file="$LOCAL_GIT_DIR/$local_basename"')
  add('    rsync -az -e "$RSYNC_SSH" "$SSH_DEST:$remote_file" "$local_file" 2>/dev/null')
  add('')
  add('    eval "$orig_editor" "\\"$local_file\\""')
  add('    editor_exit=$?')
  add('')
  add('    rsync -az -e "$RSYNC_SSH" "$local_file" "$SSH_DEST:$remote_file" 2>/dev/null')
  add('    ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" "touch \'$done_file\'"')
  add('')
  add('    wait $ssh_pid')
  add('    exit $?')
  add('  fi')
  add('')

  -- Temp file transfer
  add('  if [ -n "$temp_files" ]; then')
  add('    for tf in $temp_files; do')
  add('      tf_dir=$(dirname "$tf")')
  add('      ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" "mkdir -p \'$tf_dir\'" 2>/dev/null')
  add('      rsync -az -e "$RSYNC_SSH" "$tf" "$SSH_DEST:$tf" 2>/dev/null')
  add('    done')
  add('    ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" -- "git $rewritten"')
  add('    git_exit=$?')
  add('    for tf in $temp_files; do')
  add('      ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" "rm -f \'$tf\'" 2>/dev/null')
  add('    done')
  add('    exit $git_exit')
  add('  fi')
  add('')
  add('  exec ssh -S "$SSH_SOCKET" $SSH_PORT_ARGS "$SSH_DEST" -- "git $rewritten"')
  add("}")
  add("")

  -- Per-session blocks (from all sessions, including other nvim instances)
  local session_idx = 0
  for local_path, session_data in pairs(all_sessions) do
    -- session_data is from manifest, may not have all fields
    -- Try to get fresh info from M._sessions if available
    local session = M._sessions[local_path] or {}
    local info = session.project_info or {
      host = session_data.host,
      remote_path = session_data.remote_path,
      local_path = session_data.local_path,
      name = session_data.name,
    }
    local git_dir = session.git_dir or session_data.git_dir
    local remote_git_dir = session.remote_git_dir or session_data.remote_git_dir

    local ssh_args, parsed = ssh.get_ssh_args(info.host)
    if ssh_args and parsed then
      local dest = get_ssh_dest(parsed)
      if not git_dir then
        git_dir = info.local_path .. "/.git"
      end
      if not remote_git_dir then
        remote_git_dir = info.remote_path .. "/.git"
      end

      local socket = ""
      for i, a in ipairs(ssh_args) do
        if a == "-S" and ssh_args[i + 1] then
          socket = ssh_args[i + 1]
          break
        end
      end

      local port_args = parsed.port and ("-p " .. parsed.port) or ""
      local rsync_ssh = "ssh -S " .. socket
      if port_args ~= "" then
        rsync_ssh = rsync_ssh .. " " .. port_args
      end

      add("# --- Session " .. session_idx .. ": " .. info.name .. " ---")
      add("LOCAL_ROOT=" .. shell_quote(info.local_path))
      add("REMOTE_ROOT=" .. shell_quote(info.remote_path))
      add("LOCAL_GIT_DIR=" .. shell_quote(git_dir))
      add("REMOTE_GIT_DIR=" .. shell_quote(remote_git_dir))
      add("SSH_SOCKET=" .. shell_quote(socket))
      add("SSH_DEST=" .. shell_quote(dest))
      add("SSH_PORT_ARGS=" .. shell_quote(port_args))
      add("RSYNC_SSH=" .. shell_quote(rsync_ssh))
      add("")

      -- Detection logic
      add("is_remote=false")
      add("has_git_dir_arg=false")
      add("has_C_arg=false")
      add("check_C_next=false")
      add("remote_cwd=''")
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
      add('if [ "$is_remote" = "true" ]; then')
      add('  _rewrite_and_proxy "$@"')
      add('fi')
      add('')

      session_idx = session_idx + 1
    end
  end

  -- Fallback to real git
  add('exec "$REAL_GIT" "$@"')
  add("")

  vim.fn.writefile(lines, wrapper_path)
  vim.fn.setfperm(wrapper_path, "rwx------")
  M._wrapper_path = wrapper_path
end

---Configure fugitive to use the wrapper script
---@param wrapper_path string
function M.configure_fugitive(wrapper_path)
  vim.g.fugitive_git_executable = wrapper_path

  -- Trigger fugitive detection on all sessions
  if vim.fn.exists("*FugitiveDetect") == 1 then
    for _, session in pairs(M._sessions) do
      vim.fn.FugitiveDetect(session.project_info.local_path)
    end
  end
end

---Full setup: detect -> shim -> wrapper -> fugitive config
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

    local key = project_info.local_path
    local session = {
      project_info = project_info,
      remote_git_dir = remote_git_dir,
      git_dir = nil,
      prev_head = nil,
    }
    M._sessions[key] = session

    -- Write manifest so other nvim instances know about this session
    M._write_manifest(key, session)

    M.create_shim(project_info, session, function(shim_err)
      if shim_err then
        M._sessions[key] = nil
        M._delete_manifest(key)
        callback(shim_err)
        return
      end

      vim.schedule(function()
        -- Save originals on first session
        if M._original_path == nil then
          M._original_path = vim.env.PATH
        end
        if M._original_fugitive == nil then
          M._original_fugitive = vim.g.fugitive_git_executable or false
        end

        local ok, err = pcall(M._regenerate_wrapper)
        if not ok then
          M._sessions[key] = nil
          callback("Wrapper creation failed: " .. tostring(err))
          return
        end

        -- Prepend wrapper's bin dir to PATH
        if M._wrapper_path then
          local bin_dir = vim.fn.fnamemodify(M._wrapper_path, ":h")
          -- Only prepend if not already there
          if not vim.env.PATH:find(bin_dir, 1, true) then
            vim.env.PATH = bin_dir .. ":" .. (M._original_path or vim.env.PATH)
          end

          if git_cfg.fugitive then
            M.configure_fugitive(M._wrapper_path)
          end
        end

        vim.notify("[nvim-client-render] Git integration active", vim.log.levels.INFO)
        callback(nil)
      end)
    end)
  end)
end

---Clean up git integration for a specific session or all
---@param local_path string|nil  session key, or nil for all
function M.teardown(local_path)
  if local_path then
    M._sessions[local_path] = nil
    -- Delete manifest so other nvim instances don't include this session
    M._delete_manifest(local_path)
    M._regenerate_wrapper()
  else
    -- Delete all manifests for this instance's sessions
    for key in pairs(M._sessions) do
      M._delete_manifest(key)
    end
    M._sessions = {}
    M._regenerate_wrapper()
  end
end

---Handle FugitiveChanged autocmd — determine session from buffer, sync that session
function M.on_fugitive_changed()
  local project = require("nvim-client-render.project")
  local session_info = project.get_for_context()

  local session_key = session_info and session_info.local_path or nil
  local session = session_key and M._sessions[session_key] or nil

  -- Fallback: use first session
  if not session then
    for k, s in pairs(M._sessions) do
      session_key = k
      session = s
      break
    end
  end

  if not session then return end

  M.sync_metadata(session_key, function(err)
    if err then return end
    if not session.git_dir then return end

    local head = vim.fn.readfile(session.git_dir .. "/HEAD")
    if not head or #head == 0 then return end

    local current_head = head[1]
    if session.prev_head and current_head ~= session.prev_head then
      session.prev_head = current_head

      if config.values.git.resync_on_branch_change then
        local proj = require("nvim-client-render.project")
        proj.refresh()
      end
    else
      session.prev_head = current_head
    end
  end)
end

---Run an arbitrary git command on the remote and return output
---@param args string
---@param callback fun(code: number, stdout: string[], stderr: string[])
---@param local_path string|nil  session key, defaults to context-aware lookup
function M.exec(args, callback, local_path)
  local session
  if local_path then
    session = M._sessions[local_path]
  else
    local project = require("nvim-client-render.project")
    local info = project.get_for_context()
    if info then
      session = M._sessions[info.local_path]
    end
  end

  if not session or not session.project_info then
    vim.schedule(function() callback(1, {}, { "Git not initialized" }) end)
    return
  end

  local info = session.project_info
  local cmd = "cd " .. shell_quote(info.remote_path) .. " && git " .. args
  ssh.exec(info.host, cmd, callback)
end

---Get session for a given local_path (exposed for commands)
---@param local_path string
---@return GitSession|nil
function M.get_session(local_path)
  return M._sessions[local_path]
end

return M
