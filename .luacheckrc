-- Nakama 回调签名需要参数占位，忽略此类无害警告
unused_args = false
unused_loopvars = false
max_line_length = false

-- pcall 未使用的错误变量（err/ar_err/_cursor 等）
ignore = {"021", "122", "031", "151"}
