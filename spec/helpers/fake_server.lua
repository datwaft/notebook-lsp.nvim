-- An in-process language server for protocol tests. It records every message
-- it receives and answers requests with `handlers`, so tests can check both
-- what the plugin sends to servers and what it makes of their answers.
local M = {}

--- Capabilities of a typical Python server with notebook support.
---@type lsp.ServerCapabilities
M.capabilities = {
  textDocumentSync = { openClose = true, change = 2, save = true },
  notebookDocumentSync = { notebookSelector = { { cells = { { language = "python" } } } }, save = true },
  hoverProvider = true,
  definitionProvider = true,
  completionProvider = { resolveProvider = true, triggerCharacters = { "." } },
  codeActionProvider = { resolveProvider = true },
  renameProvider = true,
  documentFormattingProvider = true,
}

---@class FakeServer
---@field cmd fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.Client
---@field messages {method: string, params: any}[] every message received, in order
---@field handlers table<string, fun(params: any): any> answers to requests; others get a null result, except
--- */resolve requests, which get their item back
---@field dispatchers vim.lsp.rpc.Dispatchers
local FakeServer = {}
FakeServer.__index = FakeServer

---@param opts? {capabilities?: lsp.ServerCapabilities, handlers?: table<string, fun(params: any): any>}
---@return FakeServer
function M.new(opts)
  opts = opts or {}
  local server = setmetatable({ messages = {}, handlers = opts.handlers or {} }, FakeServer)
  local capabilities = opts.capabilities or M.capabilities
  server.cmd = function(dispatchers)
    server.dispatchers = dispatchers
    local closing, last_id = false, 0
    return {
      request = function(method, params, callback)
        table.insert(server.messages, { method = method, params = vim.deepcopy(params) })
        last_id = last_id + 1
        local result
        if method == "initialize" then
          result = { capabilities = capabilities }
        elseif server.handlers[method] then
          result = server.handlers[method](params)
        elseif vim.endswith(method, "/resolve") then
          result = params -- like real servers, resolve an item to itself
        end
        vim.schedule(function()
          callback(nil, result)
        end)
        return true, last_id
      end,
      notify = function(method, params)
        table.insert(server.messages, { method = method, params = vim.deepcopy(params) })
        if method == "exit" then
          closing = true
          vim.schedule(function()
            dispatchers.on_exit(0, 0)
          end)
        end
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
      end,
    }
  end
  return server
end

--- Params of every received message with `method`, in order.
---@return any[]
function FakeServer:received(method)
  local params = {}
  for _, message in ipairs(self.messages) do
    if message.method == method then
      table.insert(params, message.params)
    end
  end
  return params
end

--- Waits until `count` (default 1) messages with `method` arrived and returns the params of the last of them.
function FakeServer:wait_for(method, count)
  count = count or 1
  local arrived = vim.wait(1000, function()
    return #self:received(method) >= count
  end, 5)
  assert(arrived, ("fake server: expected %d %s message(s), got %d"):format(count, method, #self:received(method)))
  return self:received(method)[count]
end

--- Sends a notification to Neovim, such as textDocument/publishDiagnostics.
function FakeServer:notify(method, params)
  self.dispatchers.notification(method, params)
end

--- Sends a request to Neovim, such as workspace/applyEdit, and returns its result.
function FakeServer:request(method, params)
  return self.dispatchers.server_request(method, params)
end

return M
