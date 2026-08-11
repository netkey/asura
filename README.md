# Asura — Middle Eastern Mythology Card Game Server

[![CI](https://github.com/netkey/asura/actions/workflows/ci.yml/badge.svg)](https://github.com/netkey/asura/actions/workflows/ci.yml)
[![Deploy](https://github.com/netkey/asura/actions/workflows/deploy.yml/badge.svg)](https://github.com/netkey/asura/actions/workflows/deploy.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Lua](https://img.shields.io/badge/Lua-5.4-blue.svg)](https://www.lua.org/)
[![Nakama](https://img.shields.io/badge/Nakama-Realtime%20Game%20Server-orange.svg)](https://heroiclabs.com/nakama/)

A real-time multiplayer card game server built on [Nakama](https://heroiclabs.com/nakama/), themed around **Middle Eastern mythology and history**. Inspired by the classic *Sanguosha* (三国杀) identity-game format, reimagined with heroes from *One Thousand and One Nights*, Persian polymaths, and historical figures like Saladin and Avicenna.

Supports **2–5 player identity matches** — Monarch, Minister, Rebel, and Traitor roles — with **30 playable heroes**, a **108-card deck**, and a complete production-grade backend.

---

## ✨ Features

- **Identity role system**: 2–5 players, classic Monarch/Minister/Rebel/Traitor win conditions
- **30 playable heroes** (and counting): Aladdin, Saladin, Avicenna, Gilgamesh, Scheherazade, Sinbad, Rumi, Khayyam, and more — each with an individual design doc in `heroes/*.md`
- **108-card deck**: attack, defense, heal, instant tricks (duel, mass-heal, counterspell, steal…), delayed tricks, weapons, armor, and horses — all with Middle Eastern-themed names (e.g. 大马士革弯刀, 沙漠之心)
- **Complete match lifecycle**: queuing, role assignment, turn flow, death handling, spectator mode
- **Meta systems**: seasons & ranked ladder (bronze → grandmaster), daily tasks, hero fragments, skin shop, achievements, friends & spectating
- **Localization-ready**: server-side i18n framework (`localization_manager.lua`) with `en`/`ar` templates and a card-name lookup table
- **Production-grade backend**:
  - 43 RPC endpoints, all wrapped in a `safe_rpc` layer with strict input validation against untrusted client payloads
  - OCC (optimistic concurrency control) storage writes to avoid TOCTOU races
  - Rate limiting, graceful server draining via `match_terminate`
  - Dockerized deployment with automated build → push → drain → recreate → health-check → undrain pipeline
- **Fully automated quality loop**: CI linting on every push, self-hosted deploy, and scheduled bot tests that run randomized matches against the live server to catch crashes and deadlocks

## 🚀 Quick Start

```bash
# 1. Start Nakama + PostgreSQL
docker compose up -d

# 2. Run local concurrent bot tests (10 randomized matches, no container needed)
lua5.4 demo_concurrent.lua

# 3. Lint
luacheck --no-color .
luac -p *.lua heroes/*.lua
```

## 🛠 Tech Stack

| Layer | Technology |
|-------|-----------|
| Game server | Nakama (Lua modules) |
| Storage | PostgreSQL 15 |
| Deployment | Docker + GitHub Actions self-hosted runner, ghcr.io image registry |
| CI/CD | luacheck + luac -p, automated deploy, scheduled bot tests |
| Testing | `nakama_bot_test.py` — full player-session simulation harness |

## 📁 Project Structure

```
├── api.lua                    # 43 RPC endpoints (all safe_rpc-wrapped)
├── match_handler.lua          # Match lifecycle: queuing → roles → turns → death → spectate
├── game_rules.lua             # Core rules engine (cards, turns, win conditions)
├── card_deck.lua              # 108-card deck, Middle Eastern-themed names
├── hero_manager.lua           # Hero skill triggers
├── hero_catalog.lua           # Hero registry
├── game_config.lua            # Server-side config (loaded from storage)
├── season_manager.lua         # Ranked ladder + match history
├── daily_task_manager.lua     # Daily tasks (UTC+3 reset, wins → fragments)
├── fragment_manager.lua       # Hero fragment exchange/convert/gift
├── localization_manager.lua   # i18n: broadcast helpers + locale bundles
├── rate_limiter.lua           # RPC rate limiting
├── achievement_manager.lua    # Achievement system
├── skin_catalog.lua           # Skin registry
├── locales/                   # en.lua / ar.lua / card_names.lua
├── heroes/                    # 30 hero skill modules + design docs
├── docs/                      # Architecture, API, product design docs
└── .github/workflows/         # CI, deploy, scheduled-test
```

## 👥 Heroes (30)

| # | Hero | Origin |
|---|------|--------|
| 1 | Aladdin | One Thousand and One Nights |
| 2 | Alibaba | One Thousand and One Nights |
| 3 | Saladin | Ayyubid dynasty founder |
| 4 | Hakim | Fatimid caliph |
| 5 | Al-Biruni | Persian polymath |
| 6 | Al-Khwarizmi | Mathematician, "father of algebra" |
| 7 | Al-Mansur | Abbasid caliph |
| 8 | Antar | Arabian knight-poet |
| 9 | Avicenna | Persian physician/philosopher |
| 10 | Basira | Original character |
| 11 | Dhul-Qarnayn | Quranic figure |
| 12 | Dunyazad | One Thousand and One Nights |
| 13 | Enheduanna | Mesopotamian priestess |
| 14 | Gilgamesh | Mesopotamian epic |
| 15 | Harun al-Rashid | Abbasid caliph |
| 16 | Hulagu | Ilkhanate founder |
| 17 | Ibn Battuta | Moroccan traveler |
| 18 | Imru al-Qais | Arabic poet |
| 19 | Jafar | Barmakid vizier |
| 20 | Khayyam | Persian poet/mathematician |
| 21 | Muawiyah | Umayyad dynasty founder |
| 22 | Nefertiti | Ancient Egyptian queen |
| 23 | Nizam al-Mulk | Seljuk vizier |
| 24 | Rumi | Persian poet and philosopher |
| 25 | Scheherazade | One Thousand and One Nights narrator |
| 26 | Sinbad | One Thousand and One Nights sailor |
| 27 | Suleiman | Ottoman sultan |
| 28 | Tamerlane | Timurid Empire founder |
| 29 | Zenobia | Palmyrene queen |
| 30 | Zubaydah | Abbasid queen |

## 🎮 Game Modes

**Standard (2–5 players)**: each player draws a secret identity — Monarch, Minister(s), Rebel(s), or Traitor — and must deduce allies and enemies while managing health, hand, and equipped cards.

## 📚 Documentation

- [Product design](docs/product_design.md)
- [Architecture](docs/architecture.md)
- [Backend API](docs/backend_api.md) (for client integration)
- [Hero design reviews](docs/hero_design_review.md)

## 🧪 How We Test

Every push runs `luacheck` + `luac -p`. A scheduled workflow then runs **randomized bot matches** against the deployed server via `nakama_bot_test.py`, which simulates full player sessions to exercise concurrency paths. Crashes and deadlocks are auto-analyzed and filed as GitHub issues.

## 🤝 Contributing

Contributions welcome — new heroes, balance tuning, localization (Arabic is a work in progress), docs, or client work. Open an issue first for larger changes.

## 📄 License

[MIT](LICENSE)
