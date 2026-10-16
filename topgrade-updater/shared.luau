--!nonstrict
local M = { STATE = "topgrade_updater_state", REQUEST = "topgrade_updater_request" }
function M.request(action)
    local previous = noctalia.state.get(M.REQUEST)
    noctalia.state.set(M.REQUEST, { nonce = (previous and previous.nonce or 0) + 1, action = action })
end
return M
