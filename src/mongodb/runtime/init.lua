local contract = require("mongodb.runtime.contract")

local M = {
  cancelled_error = contract.cancelled_error,
  check = contract.check,
  deadline_after = contract.deadline_after,
  remaining = contract.remaining,
  required_capabilities = contract.required_capabilities,
  timeout_error = contract.timeout_error,
  validate = contract.validate,
}

function M.copas(options)
  return require("mongodb.runtime.copas").new(options)
end

return M
