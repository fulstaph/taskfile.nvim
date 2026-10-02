local M = {}

local last_task ---@type { dir: string, name: string }?

---@param bin string
---@param dir string
---@param all boolean
---@return string[]
function M.list_argv(bin, dir, all)
  return { bin, "--dir", dir, all and "--list-all" or "--list", "--json" }
end

---@param bin string
---@param dir string
---@param name string
---@param dry boolean
---@return string[]
function M.run_argv(bin, dir, name, dry)
  local argv = { bin, "--dir", dir }
  if dry then
    argv[#argv + 1] = "--dry"
  end
  argv[#argv + 1] = name
  return argv
end

---@param stdout string
---@return { tasks: table[], location: string? }?, string?
function M.parse_list(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok or type(decoded) ~= "table" or type(decoded.tasks) ~= "table" then
    return nil, "task --list --json returned no task list"
  end
  return { tasks = decoded.tasks, location = decoded.location }
end

local function find_task_binary()
  local found = vim.fn.exepath("task")
  if found == "" then
    return nil
  end
  return found
end

local function current_working_directory()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    return vim.fn.fnamemodify(name, ":p:h")
  end
  return vim.fn.getcwd()
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.ERROR, { title = "Taskfile" })
end

---@param dir string
---@param all boolean
---@return { tasks: table[], location: string? }?, string?
local function list_tasks(dir, all)
  local task = find_task_binary()
  if not task then
    return nil, "task is not on PATH (https://taskfile.dev/installation)"
  end
  local result = vim.system(M.list_argv(task, dir, all), { text = true }):wait()
  if result.code ~= 0 then
    local err =
      vim.trim((result.stderr and result.stderr ~= "" and result.stderr) or result.stdout or "task --list failed")
    return nil, err
  end
  return M.parse_list(result.stdout)
end

---@param task table
---@param root string?
---@return table
local function task_picker_item(task, root)
  local location = task.location or {}
  local file = location.taskfile or root
  local name = task.name or task.task or ""
  local desc = task.desc or ""
  local summary = task.summary or ""
  return {
    text = table.concat({ name, desc, summary }, " "),
    name = name,
    desc = desc,
    summary = summary,
    file = file,
    pos = { location.line or 1, math.max((location.column or 1) - 1, 0) },
  }
end

local run_sequence = 0

---@param dir string
---@param name string
---@param dry boolean
function M.run(dir, name, dry)
  local task = find_task_binary()
  if not task then
    notify("task is not on PATH (https://taskfile.dev/installation)")
    return
  end
  if not dry then
    last_task = { dir = dir, name = name }
  end
  run_sequence = run_sequence + 1
  require("snacks").terminal.open(M.run_argv(task, dir, name, dry), {
    cwd = dir,
    count = run_sequence,
    auto_close = false,
    interactive = true,
  })
end

function M.rerun()
  if not last_task then
    notify("No task has been run in this session", vim.log.levels.WARN)
    return
  end
  M.run(last_task.dir, last_task.name, false)
end

---@param all boolean
---@param dry boolean
function M.pick(all, dry)
  local dir = current_working_directory()
  local listed, err = list_tasks(dir, all)
  if not listed then
    notify(err)
    return
  end
  local items = {}
  for _, task in ipairs(listed.tasks) do
    if task.name or task.task then
      items[#items + 1] = task_picker_item(task, listed.location)
    end
  end
  if #items == 0 then
    notify("No tasks in " .. (listed.location or dir), vim.log.levels.WARN)
    return
  end
  require("snacks").picker.pick({
    title = dry and "Task (dry)" or "Task",
    items = items,
    format = function(entry)
      local row = { { entry.name, "SnacksPickerLabel" } }
      if entry.desc ~= "" then
        row[#row + 1] = { "  " .. entry.desc, "SnacksPickerComment" }
      end
      return row
    end,
    preview = "file",
    confirm = function(picker, entry)
      picker:close()
      if entry then
        M.run(dir, entry.name, dry)
      end
    end,
  })
end

function M.edit()
  local dir = current_working_directory()
  local listed, err = list_tasks(dir, false)
  if not listed then
    notify(err)
    return
  end
  if not listed.location or listed.location == "" then
    notify("task did not report a Taskfile path")
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(listed.location))
end

local namespace = vim.api.nvim_create_namespace("taskfile")
local buffer_states = {}
local taskfile_patterns = { "Taskfile.yml", "Taskfile.yaml", "taskfile.yml", "taskfile.yaml" }

---@param tasks table[]
---@param bufpath string
---@return { line: integer, col: integer, name: string, public: boolean }[]
function M.marks_for(tasks, bufpath)
  local norm = vim.fs.normalize(bufpath)
  local marks = {}
  for _, task in ipairs(tasks) do
    local location = task.location or {}
    local file = location.taskfile and vim.fs.normalize(location.taskfile)
    local name = task.name or task.task
    if file == norm and type(location.line) == "number" and location.line > 0 and location.line % 1 == 0 and name then
      marks[#marks + 1] = {
        line = location.line,
        col = math.max((location.column or 1) - 1, 0),
        name = name,
        public = type(task.desc) == "string" and task.desc ~= "",
      }
    end
  end
  table.sort(marks, function(a, b)
    return a.line < b.line
  end)
  return marks
end

---@param marks { line: integer, name: string }[]
---@param line integer
---@return { line: integer, name: string }?
function M.task_at(marks, line)
  local found
  for _, mark in ipairs(marks) do
    if mark.line > line then
      break
    end
    found = mark
  end
  return found
end

local function highlights()
  vim.api.nvim_set_hl(0, "TaskfileRunnable", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "TaskfileInternal", { link = "Comment", default = true })
end

local function clear_marks(buf)
  buffer_states[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  end
end

local function is_current_buffer_state(buf, state)
  return buffer_states[buf] == state
    and vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_is_loaded(buf)
    and vim.api.nvim_buf_get_name(buf) == state.path
    and vim.api.nvim_buf_get_changedtick(buf) == state.changedtick
    and not vim.bo[buf].modified
end

local function apply_marks(buf, state, tasks)
  local marks = {}
  local line_count = vim.api.nvim_buf_line_count(buf)
  highlights()
  for _, mark in ipairs(M.marks_for(tasks, state.path)) do
    if mark.line <= line_count then
      local line = vim.api.nvim_buf_get_lines(buf, mark.line - 1, mark.line, false)[1]
      vim.api.nvim_buf_set_extmark(buf, namespace, mark.line - 1, math.min(mark.col, #line), {
        virt_text = { { mark.public and "▶ " or "▷ ", mark.public and "TaskfileRunnable" or "TaskfileInternal" } },
        virt_text_pos = "inline",
        hl_mode = "combine",
      })
      marks[#marks + 1] = mark
    end
  end
  state.marks = marks
end

---@param buf integer
function M.mark(buf)
  clear_marks(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].modified then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return
  end
  local task = find_task_binary()
  if not task then
    return
  end
  local state = { path = path, changedtick = vim.api.nvim_buf_get_changedtick(buf) }
  buffer_states[buf] = state
  local dir = vim.fn.fnamemodify(path, ":p:h")
  vim.system(M.list_argv(task, dir, true), { text = true }, function(result)
    vim.schedule(function()
      -- Each request owns one saved buffer snapshot; newer requests supersede it.
      if buffer_states[buf] ~= state then
        return
      end
      if not is_current_buffer_state(buf, state) or result.code ~= 0 then
        clear_marks(buf)
        return
      end
      local listed = M.parse_list(result.stdout)
      if not listed then
        clear_marks(buf)
        return
      end
      apply_marks(buf, state, listed.tasks)
    end)
  end)
end

function M.run_cursor()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].modified then
    notify("Save the Taskfile before running a task at the cursor", vim.log.levels.WARN)
    return
  end
  local state = buffer_states[buf]
  if not state or not state.marks or not is_current_buffer_state(buf, state) then
    clear_marks(buf)
    notify("No runnable tasks in this buffer", vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local mark = M.task_at(state.marks, line)
  if not mark then
    notify("Cursor is above the first task", vim.log.levels.WARN)
    return
  end
  M.run(current_working_directory(), mark.name, false)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("taskfile_marks", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    pattern = taskfile_patterns,
    callback = function(event)
      -- Reading and writing finish updating changedtick after these events.
      vim.schedule(function()
        M.mark(event.buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWipeout" }, {
    group = group,
    pattern = taskfile_patterns,
    callback = function(event)
      local state = buffer_states[event.buf]
      if event.event == "BufWipeout" or (state and not is_current_buffer_state(event.buf, state)) then
        clear_marks(event.buf)
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local basename = vim.fs.basename(vim.api.nvim_buf_get_name(buf))
    if vim.tbl_contains(taskfile_patterns, basename) then
      vim.schedule(function()
        M.mark(buf)
      end)
    end
  end
end

return M
