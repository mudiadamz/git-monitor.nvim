-- git-monitor.nvim
-- ===========================================================================
-- A floating panel that monitors AND controls a parent repo plus each nested
-- git sub-repo (the polyrepo layout: parent/, parent/sub-a, parent/sub-b, ...)
--
--   Repo | Branch | Local | Upstream
--     Local    = commits ahead  (you have, upstream doesn't / unpushed)
--     Upstream = commits behind (upstream has, you don't / unpulled)
--     '*' after a repo name = uncommitted local changes
--     '(fetch)' / '(pull)' / '(push)' = an op is running on that repo
--
-- The panel opens INSTANTLY with '...' placeholders, then each row fills in
-- asynchronously (vim.system). One `git status --porcelain=v2 --branch` per
-- repo yields branch + ahead/behind + dirty in a single call. git runs
-- list-form / direct (no shell), so a non-POSIX 'shell' (e.g. PowerShell) is
-- irrelevant. Network ops set GIT_TERMINAL_PROMPT=0 so a missing credential
-- fails fast instead of hanging.
--
-- Panel keys:
--   r          fetch ALL repos, then refresh counts
--   p / P      pull / push the repo under the cursor (P confirms first)
--   <leader>p / <leader>P   pull / push ALL repos (each confirms)
--   q / <Esc>  close
-- pull = stash (if dirty) -> pull -> stash pop.
-- ===========================================================================

local M = {}
local uv = vim.uv or vim.loop

-- ---- config -------------------------------------------------------------
local config = {
  keymap = nil,                                 -- e.g. "<leader>gm"; nil = none
  highlight = { bg = "#2f5b8c", bold = true },  -- selected-row highlight
  root = nil,                                   -- fun(): string dir; nil = default
}

-- Default root: the root of an OPEN NERDTree window in this tab (filetype probe,
-- no hard dependency), else Neovim's cwd.
local function default_root()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "nerdtree" then
      local ok, r = pcall(vim.fn.eval, "g:NERDTree.ForCurrentTab().root.path.str()")
      if ok and type(r) == "string" and r ~= "" and vim.fn.isdirectory(r) == 1 then
        return r
      end
    end
  end
  return uv.cwd()
end

function M.root()
  return (config.root or default_root)()
end

-- ---- git ----------------------------------------------------------------
local STATUS_CMD = { "status", "--porcelain=v2", "--branch" }

-- Run `git -C dir <args>`; on_done({code, stdout, stderr}) on the main loop.
local function run(dir, args, on_done)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  if type(vim.system) == "function" then
    vim.system(cmd, { text = true, clear_env = false, env = { GIT_TERMINAL_PROMPT = "0" } }, function(res)
      vim.schedule(function()
        on_done({ code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" })
      end)
    end)
  else
    local out = table.concat(vim.fn.systemlist(cmd), "\n")
    on_done({ code = vim.v.shell_error, stdout = out, stderr = out })
  end
end

local function parse_v2(text)
  local st = { branch = "?", ahead = 0, behind = 0, upstream = false, dirty = false }
  for _, l in ipairs(vim.split(text or "", "\n")) do
    if l:sub(1, 1) == "#" then
      if l:find("^# branch%.head ") then
        st.branch = (l:gsub("^# branch%.head ", ""))
      elseif l:find("^# branch%.upstream ") then
        st.upstream = true
      elseif l:find("^# branch%.ab ") then
        local a, b = l:match("%+(%d+)%s+%-(%d+)")
        st.ahead, st.behind = tonumber(a) or 0, tonumber(b) or 0
      end
    elseif l ~= "" then
      st.dirty = true
    end
  end
  return st
end

local function status_sync(dir)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, STATUS_CMD)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return { branch = "?", ahead = 0, behind = 0, upstream = false, dirty = false }
  end
  return parse_v2(table.concat(out, "\n"))
end

local function discover(root)
  local list = {}
  if uv.fs_stat(root .. "/.git") then
    list[#list + 1] = { name = "root", dir = root }
  end
  local names = {}
  for name, t in vim.fs.dir(root) do
    if t == "directory" and uv.fs_stat(root .. "/" .. name .. "/.git") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, n in ipairs(names) do
    list[#list + 1] = { name = n, dir = root .. "/" .. n }
  end
  return list
end

-- Synchronous full collect (blocks). For programmatic use / tests.
function M.collect(root)
  root = root or M.root()
  local repos = {}
  for _, r in ipairs(discover(root)) do
    local st = status_sync(r.dir)
    st.name, st.dir = r.name, r.dir
    repos[#repos + 1] = st
  end
  return { root = root, repos = repos }
end

-- Build aligned table lines. branch == nil => '...' placeholder (loading).
-- Reads optional r.busy (op label) and r.dirty. Pure — used by panel + tests.
function M.render(data)
  if #data.repos == 0 then
    return { " No git repos under " .. data.root }
  end
  local rows = { { "Repo", "Branch", "Local", "Upstream" } }
  for _, r in ipairs(data.repos) do
    local loading = (r.branch == nil)
    local nm = r.name
    if r.busy then
      nm = nm .. " (" .. r.busy .. ")"
    elseif r.dirty then
      nm = nm .. " *"
    end
    rows[#rows + 1] = {
      nm,
      loading and "..." or r.branch,
      loading and "..." or tostring(r.ahead),
      loading and "..." or (r.upstream and tostring(r.behind) or "-"),
    }
  end
  local w = { 0, 0, 0, 0 }
  for _, row in ipairs(rows) do
    for i, c in ipairs(row) do
      w[i] = math.max(w[i], #c)
    end
  end
  local function fmt(row)
    local parts = {}
    for i, c in ipairs(row) do
      parts[i] = c .. string.rep(" ", w[i] - #c)
    end
    return " " .. table.concat(parts, "  |  ") .. " "
  end
  local lines = { fmt(rows[1]) }
  lines[2] = string.rep("-", #lines[1])
  for i = 2, #rows do
    lines[#lines + 1] = fmt(rows[i])
  end
  lines[#lines + 1] = " p:pull  P:push  \\p:pull-all  \\P:push-all   r:fetch  q:close "
  return lines
end

-- ---- panel window -------------------------------------------------------
local state = { win = nil, buf = nil, root = nil, repos = nil }

local function data_from_state()
  local repos = {}
  for _, r in ipairs(state.repos or {}) do
    local row = { name = r.name, busy = r.busy }
    if r.status then
      row.branch, row.ahead, row.behind = r.status.branch, r.status.ahead, r.status.behind
      row.upstream, row.dirty = r.status.upstream, r.status.dirty
    end
    repos[#repos + 1] = row
  end
  return { root = state.root, repos = repos }
end

local function repo_under_cursor()
  if not state.repos or #state.repos == 0 then
    return nil
  end
  local idx = vim.api.nvim_win_get_cursor(0)[1] - 2 -- header + separator
  return state.repos[idx]
end

local function draw()
  local lines = M.render(data_from_state())
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].filetype = "gitmonitor"
    local o = { buffer = state.buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", M.close, o)
    vim.keymap.set("n", "<Esc>", M.close, o)
    vim.keymap.set("n", "r", M.refresh, o)
    vim.keymap.set("n", "p", function() local r = repo_under_cursor(); if r then M.pull_repo(r) end end, o)
    vim.keymap.set("n", "P", M.push_current, o)
    vim.keymap.set("n", "<leader>p", M.pull_all, o)
    vim.keymap.set("n", "<leader>P", M.push_all, o)
    -- Keep the cursor on repo rows only, so j/k moves repo-to-repo and the
    -- cursorline highlight always sits on a real repo.
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = state.buf,
      callback = function()
        local n = #(state.repos or {})
        if n == 0 then return end
        local first, last = 3, 2 + n
        local l = vim.api.nvim_win_get_cursor(0)[1]
        if l < first then
          vim.api.nvim_win_set_cursor(0, { first, 0 })
        elseif l > last then
          vim.api.nvim_win_set_cursor(0, { last, 0 })
        end
      end,
    })
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  local width = 30
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  local cfg = {
    relative = "editor",
    width = width,
    height = #lines,
    row = math.max(math.floor((vim.o.lines - #lines) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = "minimal",
    border = "rounded",
    title = " git monitor ",
    title_pos = "center",
  }
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_buf(state.win, state.buf)
    vim.api.nvim_win_set_config(state.win, cfg)
  else
    state.win = vim.api.nvim_open_win(state.buf, true, cfg)
    vim.api.nvim_set_hl(0, "GitMonitorSel", config.highlight)
    vim.wo[state.win].cursorline = true
    vim.wo[state.win].cursorlineopt = "line"
    vim.wo[state.win].winhighlight = "CursorLine:GitMonitorSel"
    if #(state.repos or {}) > 0 then
      pcall(vim.api.nvim_win_set_cursor, state.win, { 3, 0 })
    end
  end
end

local function update()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    draw()
  end
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

local function status_async(r, done)
  run(r.dir, STATUS_CMD, function(res)
    r.status = parse_v2(res.code == 0 and res.stdout or "")
    update()
    if done then done(r.status) end
  end)
end

-- ---- actions ------------------------------------------------------------

-- Yes/No confirm, default No. A module field so tests can stub it.
function M.confirm(msg)
  return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
end

-- Pull: stash (if dirty) -> pull -> stash pop. opts = { quiet, done }.
function M.pull_repo(r, opts)
  opts = opts or {}
  local dirty = r.status and r.status.dirty
  r.busy = "pull"; update()
  local function finish(res)
    r.busy = nil
    if res and res.code ~= 0 then
      vim.notify("git pull " .. r.name .. ": " .. vim.trim(res.stderr ~= "" and res.stderr or res.stdout),
        vim.log.levels.ERROR)
    elseif not opts.quiet then
      vim.notify("git pull " .. r.name .. ": ok", vim.log.levels.INFO)
    end
    status_async(r, function() if opts.done then opts.done(res) end end)
  end
  local function do_pull()
    run(r.dir, { "pull" }, function(res_pull)
      if dirty then
        run(r.dir, { "stash", "pop" }, function() finish(res_pull) end)
      else
        finish(res_pull)
      end
    end)
  end
  if dirty then
    run(r.dir, { "stash", "push", "--include-untracked", "-q" }, function() do_pull() end)
  else
    do_pull()
  end
end

-- Push. opts = { quiet, done }.
function M.push_repo(r, opts)
  opts = opts or {}
  r.busy = "push"; update()
  run(r.dir, { "push" }, function(res)
    r.busy = nil
    if res.code ~= 0 then
      vim.notify("git push " .. r.name .. ": " .. vim.trim(res.stderr ~= "" and res.stderr or res.stdout),
        vim.log.levels.ERROR)
    elseif not opts.quiet then
      vim.notify("git push " .. r.name .. ": ok", vim.log.levels.INFO)
    end
    status_async(r, function() if opts.done then opts.done(res) end end)
  end)
end

-- Push the repo under the cursor, after a confirm (push publishes commits).
function M.push_current()
  local r = repo_under_cursor()
  if r and M.confirm("Push " .. r.name .. "?") then
    M.push_repo(r)
  end
end

function M.pull_all()
  local repos = state.repos or {}
  if #repos == 0 then return end
  if not M.confirm("Pull ALL " .. #repos .. " repos (stash+pull+pop)?") then return end
  for _, r in ipairs(repos) do M.pull_repo(r, { quiet = true }) end
end

function M.push_all()
  local repos = state.repos or {}
  if #repos == 0 then return end
  if not M.confirm("Push ALL " .. #repos .. " repos?") then return end
  for _, r in ipairs(repos) do M.push_repo(r, { quiet = true }) end
end

-- Refresh: git fetch every repo, then re-read status. done() optional.
function M.refresh(done)
  local repos = state.repos or {}
  for _, r in ipairs(repos) do r.busy = "fetch" end
  update()
  local pending = #repos
  if pending == 0 then if done then done() end; return end
  for _, r in ipairs(repos) do
    run(r.dir, { "fetch", "--quiet" }, function()
      r.busy = nil
      status_async(r, function()
        pending = pending - 1
        if pending == 0 and done then done() end
      end)
    end)
  end
end

-- Open the panel immediately (placeholders), then fill each repo async.
function M.open()
  local root = M.root()
  local repos = discover(root)
  for _, r in ipairs(repos) do
    r.status, r.busy = nil, nil
  end
  state.root, state.repos = root, repos
  draw()
  for _, r in ipairs(repos) do
    status_async(r)
  end
end

-- setup: apply config, create the :GitMonitor command + optional keymap.
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  vim.api.nvim_create_user_command("GitMonitor", M.open, { desc = "Multi-repo git monitor" })
  if config.keymap then
    vim.keymap.set("n", config.keymap, M.open, { silent = true, desc = "git: multi-repo monitor" })
  end
  return M
end

return M
