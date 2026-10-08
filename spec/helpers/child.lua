-- Drives a separate Neovim process for end-to-end tests, so clients, server
-- processes and autocmds can't leak from one test into the next.
local tools = require("helpers.tools")

local M = {}

---@class Child
---@field channel integer
local Child = {}
Child.__index = Child

--- Starts `nvim --clean --embed --headless` with this plugin and the spec
--- helpers loadable.
---@return Child
function M.start()
  local channel = vim.fn.jobstart(
    { vim.v.progpath, "--clean", "--embed", "--headless" },
    { rpc = true, env = tools.env }
  )
  local child = setmetatable({ channel = channel }, Child)
  child:lua(
    [[
      local root = ...
      vim.opt.runtimepath:prepend(root)
      package.path = root .. "/spec/?.lua;" .. package.path
    ]],
    tools.root
  )
  return child
end

--- Runs a Lua chunk in the child with `...` as its arguments, and returns its result.
---@param code string
---@return any
function Child:lua(code, ...)
  local result = vim.rpcrequest(self.channel, "nvim_exec_lua", code, { ... })
  if result == vim.NIL then -- nil doesn't survive RPC
    return nil
  end
  return result
end

--- Calls `require("helpers.in_child")[fn](...)` in the child, and returns its result.
---@param fn string
---@return any
function Child:call(fn, ...)
  return self:lua("local fn = ...; return require('helpers.in_child')[fn](select(2, ...))", fn, ...)
end

--- Waits until `fn` (see Child:call) returns a truthy value, and returns whether it did.
---@param timeout integer milliseconds
---@param fn string
function Child:wait_for(timeout, fn, ...)
  local args = { ... }
  return vim.wait(timeout, function()
    return self:call(fn, unpack(args))
  end, 100)
end

function Child:stop()
  vim.fn.jobstop(self.channel)
  vim.fn.jobwait({ self.channel }, 5000)
end

return M
