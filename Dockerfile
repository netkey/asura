FROM ghcr.io/netkey/nakama-base:3.22.0

# 拷贝 Lua 模块到 runtime path（不含 demo*.lua）
COPY *.lua /nakama/data/modules/
COPY locales/ /nakama/data/modules/locales/
COPY heroes/ /nakama/data/modules/heroes/
RUN rm -f /nakama/data/modules/demo*.lua
