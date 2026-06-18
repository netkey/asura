-- Nakama 运行时注入的全局变量
globals = {"nk"}

-- Nakama 回调签名需要参数占位，忽略此类无害警告
unused_args = false
unused_loopvars = false
max_line_length = false
max_comment_columns = false

-- 忽略：未使用变量赋值 / 变量自赋值 / 未使用循环变量 / 全局变量影子
ignore = {"021", "031", "122", "151"}
