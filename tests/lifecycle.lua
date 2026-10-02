vim.opt.rtp:prepend(vim.fn.getcwd())

local taskfile = require("taskfile")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local path = directory .. "/Taskfile.yml"
vim.fn.writefile({
  "version: '3'",
  "tasks:",
  "  build:",
  "    cmds: []",
  "",
  "  deploy:",
  "    cmds: []",
}, path)

local requests = {}
local calls = {}
vim.fn.exepath = function()
  return "/fixture/task"
end
vim.system = function(_, _, callback)
  requests[#requests + 1] = callback
  return {}
end
package.loaded.snacks = {
  terminal = {
    open = function(argv)
      calls[#calls + 1] = argv
    end,
  },
}

local function wait_for(predicate, message)
  assert(vim.wait(1000, predicate, 10), message)
end

local function respond(build_line, deploy_line)
  local tasks = {}
  for name, line in pairs({ build = build_line, deploy = deploy_line }) do
    tasks[#tasks + 1] = {
      name = name,
      location = { taskfile = vim.api.nvim_buf_get_name(0), line = line, column = 3 },
    }
  end
  requests[#requests]({ code = 0, stdout = vim.json.encode({ tasks = tasks }) })
  local namespace = vim.api.nvim_create_namespace("taskfile")
  wait_for(function()
    return #vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {}) == 2
  end, "task markers did not appear")
end

local ok, err = pcall(function()
  taskfile.setup()
  vim.cmd.edit(vim.fn.fnameescape(path))
  wait_for(function()
    return #requests > 0
  end, "reading did not list tasks")
  respond(3, 6)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  taskfile.run_cursor()
  assert(calls[1][4] == "build", "reading a Taskfile lost its markers")

  vim.api.nvim_buf_set_lines(0, 2, 2, false, { "", "" })
  local previous_request_count = #requests
  vim.cmd.write()
  wait_for(function()
    return #requests > previous_request_count
  end, "saving did not list tasks")
  respond(5, 8)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  taskfile.run_cursor()
  assert(calls[2][4] == "build", "saving a Taskfile lost its refreshed markers")
end)

vim.fn.delete(directory, "rf")
if not ok then
  error(err)
end
print("PASS: actual read and write events preserve the correct buffer snapshot")
