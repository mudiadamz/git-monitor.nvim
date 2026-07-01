-- Standalone test suite for git-monitor.nvim.
-- Run:  nvim --headless -u tests/minimal_init.lua -c "luafile tests/gitmonitor_spec.lua"
--       (or tests/run.sh / tests/run.ps1). Exits 0 if all pass, 1 on failure.
-- Self-contained: creates temp git fixtures, no external deps, no NERDTree
-- (root() falls back to cwd).

local gm = require("gitmonitor")

local passed, failed, fails = 0, 0, {}
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; fails[#fails + 1] = name end
  io.stderr:write((cond and "  ok   " or "  FAIL ") .. name .. "\n")
end
local function eq(a, b, name) ok(a == b, name .. "  (got " .. vim.inspect(a) .. ", want " .. vim.inspect(b) .. ")") end
local function group(t) io.stderr:write("\n# " .. t .. "\n") end

local function reset()
  pcall(gm.close)
  pcall(vim.cmd, "silent! tabonly!")
  pcall(vim.cmd, "silent! only!")
  pcall(vim.cmd, "silent! enew!")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) ~= "" then pcall(vim.cmd, "silent! bwipeout! " .. b) end
  end
end

local function gitc(d, a) return vim.fn.systemlist(vim.list_extend({ "git", "-C", d }, a)) end
local function panel_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "gitmonitor" then return w end
  end
end
local function panel_text()
  local w = panel_win()
  if not w then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
end

-- ---------------------------------------------------------------------------
group("module + setup")
for _, fn in ipairs({ "setup", "open", "close", "collect", "render", "root", "refresh",
  "pull_repo", "push_repo", "push_current", "pull_all", "push_all", "confirm",
  "checkout_repo", "checkout_current", "checkout_all", "input" }) do
  ok(type(gm[fn]) == "function", "M." .. fn .. " exists")
end
ok(vim.fn.exists(":GitMonitor") == 2, ":GitMonitor command created by setup()")

-- ---------------------------------------------------------------------------
group("render")
local rl = gm.render({ root = "X", repos = {
  { name = "root", branch = "dev",  ahead = 0, behind = 0, upstream = true,  dirty = false },
  { name = "core", branch = "main", ahead = 2, behind = 1, upstream = true,  dirty = true },
} })
ok(rl[1]:find("Repo") and rl[1]:find("Branch") and rl[1]:find("Local") and rl[1]:find("Upstream"),
  "header = Repo | Branch | Local | Upstream")
ok(rl[3] and rl[3]:find("root") and rl[3]:find("dev"), "row shows repo name + branch")
ok(rl[4] and rl[4]:find("core %*") and rl[4]:find("2") and rl[4]:find("1"),
  "dirty '*' + ahead/behind counts rendered")
local rp = gm.render({ root = "X", repos = { { name = "root" } } })
ok(rp[3] and rp[3]:find("root") and rp[3]:find("%.%.%."), "loading repo renders a '...' placeholder")

-- ---------------------------------------------------------------------------
group("collect + async open + highlight (temp git fixture)")
if vim.fn.executable("git") ~= 1 then
  io.stderr:write("  (git not on PATH: skipping git tests)\n")
else
  local GR = vim.fn.tempname()
  vim.fn.mkdir(GR, "p"); vim.fn.mkdir(GR .. "/sub", "p")
  local function setup_repo(d)
    gitc(d, { "init", "-q" })
    gitc(d, { "config", "user.email", "t@e" })
    gitc(d, { "config", "user.name", "t" })
    gitc(d, { "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "init" })
  end
  setup_repo(GR); setup_repo(GR .. "/sub")

  local data = gm.collect(GR)
  local names = {}
  for _, r in ipairs(data.repos) do names[#names + 1] = r.name end
  table.sort(names)
  eq(#data.repos, 2, "collect finds parent repo + 1 nested sub-repo")
  ok(vim.tbl_contains(names, "root") and vim.tbl_contains(names, "sub"),
    "repos: root + sub (got " .. table.concat(names, ",") .. ")")

  -- async open: instant placeholders, then fill
  local expected = gm.collect(GR).repos[1].branch
  reset(); vim.fn.chdir(GR); gm.open()
  local immediate = panel_text()
  ok(immediate:find("root") ~= nil, "panel opens immediately with repo rows (before git finishes)")
  ok(immediate:find(expected, 1, true) == nil, "branches show as '...' first (non-blocking async)")
  vim.wait(3000, function() return panel_text():find(expected, 1, true) ~= nil end)
  ok(panel_text():find(expected, 1, true) ~= nil, "panel fills branch '" .. expected .. "' asynchronously")

  -- highlight + cursor clamp
  local pw = panel_win()
  ok(pw ~= nil and vim.wo[pw].cursorline == true, "panel highlights current row (cursorline)")
  ok(vim.fn.hlexists("GitMonitorSel") == 1, "selection highlight group defined")
  if pw then
    vim.api.nvim_set_current_win(pw)
    ok(vim.api.nvim_win_get_cursor(pw)[1] >= 3, "cursor starts on a repo row (>=3)")
    vim.api.nvim_win_set_cursor(pw, { 1, 0 })
    vim.cmd("doautocmd CursorMoved")
    ok(vim.api.nvim_win_get_cursor(pw)[1] >= 3, "cursor clamped off the header onto a repo row")
  end

  -- push confirmation
  vim.api.nvim_win_set_cursor(pw, { 3, 0 })
  local captured, realconfirm = nil, gm.confirm
  gm.confirm = function(msg) captured = msg; return false end
  gm.push_current()
  gm.confirm = realconfirm
  ok(captured ~= nil and captured:find("Push") ~= nil, "single push (P) prompts to confirm before pushing")
  gm.close()

  -- ---- live fetch / pull / push against a bare remote --------------------
  group("live fetch / pull / push (bare remote)")
  local function stat(root, name)
    for _, x in ipairs(gm.collect(root).repos) do if x.name == name then return x end end
    return {}
  end
  local BARE = vim.fn.tempname()
  vim.fn.systemlist({ "git", "init", "--bare", "-q", BARE })
  local SEED = vim.fn.tempname()
  vim.fn.systemlist({ "git", "clone", "-q", BARE, SEED })
  gitc(SEED, { "config", "user.email", "t@e" }); gitc(SEED, { "config", "user.name", "t" })
  gitc(SEED, { "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "c1" })
  gitc(SEED, { "push", "-q", "-u", "origin", "HEAD" })

  local RT = vim.fn.tempname(); vim.fn.mkdir(RT, "p")
  vim.fn.systemlist({ "git", "clone", "-q", BARE, RT .. "/repo" })
  gitc(RT .. "/repo", { "config", "user.email", "t@e" }); gitc(RT .. "/repo", { "config", "user.name", "t" })

  vim.fn.writefile({ "x" }, RT .. "/repo/untracked.txt")
  eq(stat(RT, "repo").dirty, true, "uncommitted change marks repo dirty (asterisk)")
  vim.fn.delete(RT .. "/repo/untracked.txt")

  gitc(SEED, { "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "c2" })
  gitc(SEED, { "push", "-q" })
  reset(); vim.fn.chdir(RT); gm.open()
  vim.wait(4000, function() return stat(RT, "repo").branch ~= "?" end)
  local refreshed
  gm.refresh(function() refreshed = true end)
  vim.wait(8000, function() return refreshed == true end)
  eq(stat(RT, "repo").behind, 1, "refresh runs git fetch -> Upstream(behind)=1")

  local r = { name = "repo", dir = RT .. "/repo" }
  local pulled
  gm.pull_repo(r, { quiet = true, done = function(res) pulled = res end })
  vim.wait(8000, function() return pulled ~= nil end)
  ok(pulled and pulled.code == 0, "pull_repo succeeds (stash+pull+pop)")
  eq(stat(RT, "repo").behind, 0, "after pull -> Upstream(behind)=0")

  vim.fn.writefile({ "local" }, RT .. "/repo/local.txt")
  gitc(RT .. "/repo", { "add", "-A" })
  gitc(RT .. "/repo", { "-c", "commit.gpgsign=false", "commit", "-q", "-m", "local" })
  eq(stat(RT, "repo").ahead, 1, "local commit -> Local(ahead)=1")
  local pushed
  gm.push_repo(r, { quiet = true, done = function(res) pushed = res end })
  vim.wait(8000, function() return pushed ~= nil end)
  ok(pushed and pushed.code == 0, "push_repo succeeds")
  eq(stat(RT, "repo").ahead, 0, "after push -> Local(ahead)=0")

  -- CHECKOUT (stash+pop): switch branch, preserving WIP
  vim.fn.writefile({ "v1" }, RT .. "/repo/tracked.txt")
  gitc(RT .. "/repo", { "add", "tracked.txt" })
  gitc(RT .. "/repo", { "-c", "commit.gpgsign=false", "commit", "-q", "-m", "add tracked" })
  gitc(RT .. "/repo", { "branch", "feature" })
  vim.fn.writefile({ "v2 dirty" }, RT .. "/repo/tracked.txt")
  r.status = stat(RT, "repo")
  eq(r.status.dirty, true, "WIP present before checkout")
  local co = {}
  gm.checkout_repo(r, "feature", { quiet = true, done = function(res) co.res = res end })
  vim.wait(8000, function() return co.res ~= nil end)
  ok(co.res and co.res.code == 0, "checkout_repo (stash+pop) succeeds")
  eq(stat(RT, "repo").branch, "feature", "switched to the feature branch")
  eq(stat(RT, "repo").dirty, true, "WIP preserved across checkout (stash -> checkout -> pop)")
  gm.close()
end

-- ---------------------------------------------------------------------------
io.stderr:write(string.format("\n==== %d passed, %d failed ====\n", passed, failed))
if failed > 0 then
  io.stderr:write("FAILURES:\n  " .. table.concat(fails, "\n  ") .. "\n")
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
