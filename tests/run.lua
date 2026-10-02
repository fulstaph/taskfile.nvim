vim.opt.rtp:prepend(vim.fn.getcwd())

local taskfile = require("taskfile")
local original_system = vim.system
local original_schedule = vim.schedule
local original_notify = vim.notify
local original_exepath = vim.fn.exepath
local original_snacks = package.loaded.snacks
local pending_requests = {}
local terminal_calls = {}
local notifications = {}
local passed = 0
local failed = 0
local namespace = vim.api.nvim_create_namespace("taskfile")

vim.schedule = function(callback)
  callback()
end
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
vim.fn.exepath = function(name)
  return name == "task" and "/fixture/task" or original_exepath(name)
end
vim.system = function(argv, _, callback)
  assert(callback, "These tests expect an asynchronous task listing")
  pending_requests[#pending_requests + 1] = { argv = argv, callback = callback }
  return {}
end
package.loaded.snacks = {
  terminal = {
    open = function(argv)
      terminal_calls[#terminal_calls + 1] = argv
    end,
  },
}

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function test(name, callback)
  pending_requests = {}
  terminal_calls = {}
  notifications = {}
  local ok, err = pcall(callback)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    failed = failed + 1
    print("FAIL: " .. name .. "\n" .. err)
  end
end

local function create_buffer()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/Taskfile.yml")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "version: '3'",
    "tasks:",
    "  build:",
    "    cmds: []",
    "",
    "  deploy:",
    "    cmds: []",
  })
  vim.bo[buf].modified = false
  return buf
end

local function listed_task(buf, name, line, column)
  return {
    name = name,
    desc = name,
    location = { taskfile = vim.api.nvim_buf_get_name(buf), line = line, column = column or 3 },
  }
end

local function respond(index, tasks)
  pending_requests[index].callback({ code = 0, stdout = vim.json.encode({ tasks = tasks }) })
end

test("command arguments preserve paths and task names containing spaces", function()
  equal(taskfile.list_argv("/path with spaces/task", "/project with spaces", true), {
    "/path with spaces/task",
    "--dir",
    "/project with spaces",
    "--list-all",
    "--json",
  })
  equal(taskfile.run_argv("task", "/project", "build app", true), {
    "task",
    "--dir",
    "/project",
    "--dry",
    "build app",
  })
end)

test("invalid task JSON returns an error", function()
  for _, stdout in ipairs({ "not json", "null", '{"tasks":null}', "{}" }) do
    local listed, err = taskfile.parse_list(stdout)
    equal(listed, nil)
    assert(type(err) == "string")
  end
end)

test("marks exclude included files and sort by their source line", function()
  local buf = create_buffer()
  local included = listed_task(buf, "included", 2)
  included.location.taskfile = "/other/Taskfile.yml"
  local marks = taskfile.marks_for(
    { listed_task(buf, "deploy", 6), included, listed_task(buf, "build", 3) },
    vim.api.nvim_buf_get_name(buf)
  )
  equal(#marks, 2)
  equal(marks[1].name, "build")
  equal(marks[2].name, "deploy")
end)

test("cursor execution uses the task belonging to the saved source line", function()
  local buf = create_buffer()
  taskfile.mark(buf)
  respond(1, { listed_task(buf, "build", 3), listed_task(buf, "deploy", 6) })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  taskfile.run_cursor()
  equal(terminal_calls[1][4], "build")
end)

test("editing before a task cannot execute a different task", function()
  local buf = create_buffer()
  taskfile.mark(buf)
  respond(1, { listed_task(buf, "build", 3), listed_task(buf, "deploy", 6) })
  vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "", "", "", "", "", "", "", "", "", "" })
  vim.api.nvim_win_set_cursor(0, { 13, 0 })
  taskfile.run_cursor()
  equal(#terminal_calls, 0)
  assert(notifications[1]:match("Save the Taskfile"))
end)

test("older asynchronous responses cannot replace the newest task list", function()
  local buf = create_buffer()
  taskfile.mark(buf)
  taskfile.mark(buf)
  respond(2, { listed_task(buf, "deploy", 3) })
  respond(1, { listed_task(buf, "build", 3) })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  taskfile.run_cursor()
  equal(terminal_calls[1][4], "deploy")
end)

test("shrinking a buffer while listing tasks discards the response", function()
  local buf = create_buffer()
  taskfile.mark(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "version: '3'" })
  respond(1, { listed_task(buf, "deploy", 6) })
  equal(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), 0)
  taskfile.run_cursor()
  equal(#terminal_calls, 0)
end)

test("renamed and deleted buffers reject pending responses", function()
  local buf = create_buffer()
  taskfile.mark(buf)
  local task = listed_task(buf, "build", 3)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/Taskfile.yml")
  respond(1, { task })
  equal(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), 0)
  taskfile.mark(buf)
  task = listed_task(buf, "build", 3)
  vim.api.nvim_buf_delete(buf, { force = true })
  respond(2, { task })
end)

test("invalid source rows are skipped and oversized columns are clamped", function()
  local buf = create_buffer()
  taskfile.mark(buf)
  respond(1, {
    listed_task(buf, "build", 3, 500),
    listed_task(buf, "zero", 0),
    listed_task(buf, "fractional", 3.5),
    listed_task(buf, "beyond-buffer", 100),
  })
  local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
  equal(#marks, 1)
  equal(marks[1][2], 2)
  equal(marks[1][3], #"  build:")
end)

test("failed or malformed listings remove previously runnable tasks", function()
  local buf = create_buffer()
  taskfile.mark(buf)
  respond(1, { listed_task(buf, "build", 3) })
  taskfile.mark(buf)
  pending_requests[2].callback({ code = 1, stdout = "", stderr = "broken Taskfile" })
  taskfile.run_cursor()
  equal(#terminal_calls, 0)
  taskfile.mark(buf)
  pending_requests[3].callback({ code = 0, stdout = "malformed json" })
  taskfile.run_cursor()
  equal(#terminal_calls, 0)
end)

test("setup clears edited marks and keeps a current saved response", function()
  local buf = create_buffer()
  taskfile.setup()
  local request_index = #pending_requests
  respond(request_index, { listed_task(buf, "build", 3) })
  vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  equal(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), 0)
  vim.bo[buf].modified = false
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  request_index = #pending_requests
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  respond(request_index, { listed_task(buf, "build", 4) })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  taskfile.run_cursor()
  equal(terminal_calls[1][4], "build")
end)

vim.system = original_system
vim.schedule = original_schedule
vim.notify = original_notify
vim.fn.exepath = original_exepath
package.loaded.snacks = original_snacks
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
