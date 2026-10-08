---@meta
-- The luassert types that ship with lua_ls leave out the failure message every
-- assertion accepts as its last argument. These add it to the ones we call
-- with a message.

---@class luassert.internal
local internal = {}

---@param value any
---@param message? string shown when the assertion fails
function internal.is_true(value, message) end

---@param value any
---@param message? string shown when the assertion fails
function internal.is_false(value, message) end

---@param value any
---@param message? string shown when the assertion fails
function internal.truthy(value, message) end

---@param callback function a callback function that should error
---@param error? string the specific error message that will be asserted
---@param message? string shown when the assertion fails
function internal.has_error(callback, error, message) end
