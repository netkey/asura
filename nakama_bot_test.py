# /// script
# /// <summary>Asura Nakama Bot test — simple sequential turn loop</summary>
# /// </summary>
# ///

"""Nakama bot test — simple sequential turn loop.

Strategy: only the current-turn bot acts, one action per iteration.
All pending actions (including defense) are responded to immediately,
running in the background so the game state advances freely.

After sending a pending response, waits for the state to update (new op_code 10)
to avoid infinite loops where the server only broadcasts rescue via op_code 11.

Run: python3 nakama_bot_test.py [--rounds N] [--all] [--identity]
"""
import asyncio, aiohttp, base64, json, sys, time, websockets

NAKAMA_HOST, NAKAMA_PORT, NAKAMA_KEY = "localhost", 7350, "defaultkey"
MAX_ITER, MATCH_TIMEOUT = 1500, 300

MATCH_CONFIGS = [
    {"players": [{"id":"a1","hero":"harun_al_rashid"},{"id":"a2","hero":"khayyam"}]},
    {"players": [{"id":"b1","hero":"zenobia"},{"id":"b2","hero":"muawiyah"}]},
    {"players": [{"id":"c1","hero":"nizamulmulk"},{"id":"c2","hero":"enheduanna"}]},
    {"players": [{"id":"d1","hero":"al_mansur"},{"id":"d2","hero":"gilgamesh"}]},
    {"players": [{"id":"e1","hero":"imru_al_qais"},{"id":"e2","hero":"basira"}]},
    {"players": [{"id":"f1","hero":"aladdin"},{"id":"f2","hero":"alibaba"}]},
    {"players": [{"id":"g1","hero":"saladin"},{"id":"g2","hero":"jafar"}]},
    {"players": [{"id":"h1","hero":"hakim"},{"id":"h2","hero":"scheherazade"}]},
    {"players": [{"id":"i1","hero":"ibn_battuta"},{"id":"i2","hero":"al_khwarizmi"}]},
    {"players": [{"id":"j1","hero":"avicenna"},{"id":"j2","hero":"sinbad"}]},
    {"players": [{"id":"k1","hero":"hulagu"},{"id":"k2","hero":"nefertiti"}]},
    {"players": [{"id":"l1","hero":"rumi"},{"id":"l2","hero":"tamerlane"}]},
    {"players": [{"id":"m1","hero":"zubaydah"},{"id":"m2","hero":"al_biruni"}]},
    {"players": [{"id":"n1","hero":"dunyazad"},{"id":"n2","hero":"antar"}]},
    {"players": [{"id":"o1","hero":"suleiman"},{"id":"o2","hero":"dhul_qarnayn"}]},
    {"players": [{"id":"q1","hero":"aladdin"},{"id":"q2","hero":"hakim"},{"id":"q3","hero":"saladin"},{"id":"q4","hero":"jafar"},{"id":"q5","hero":"scheherazade"}]},
    {"players": [{"id":"r1","hero":"hulagu"},{"id":"r2","hero":"rumi"},{"id":"r3","hero":"tamerlane"},{"id":"r4","hero":"zubaydah"},{"id":"r5","hero":"sinbad"}]},
]

def ai_choose(hand, state):
    tid = None
    for p in state.get("others", []):
        if p.get("hp", 0) > 0 and (not tid or p["hp"] < tid["hp"]): tid = p
    target_id = tid.get("id") if tid else None
    me = state.get("me", {})
    my_hp = me.get("hp", 99)
    for c in hand:
        if c["type"] in ("WEAPON", "ARMOR", "HORSE"): return {"card_id": c["id"]}
    if my_hp <= 2:
        for c in hand:
            if c["type"] == "HEAL": return {"card_id": c["id"]}
    # AOE 攻击优先（全场压力）
    for c in hand:
        if c["type"] == "INSTANT_TRICK" and c.get("subtype") == "aoe_attack":
            return {"card_id": c["id"]}
    if target_id:
        for c in hand:
            if c["type"] == "ATTACK": return {"card_id": c["id"], "target_id": target_id}
    # 延时锦囊（乐不思蜀/闪电）
    if target_id:
        for c in hand:
            if c["type"] == "DELAYED_TRICK": return {"card_id": c["id"], "target_id": target_id}
    for c in hand:
        if c["type"] == "WINE": return {"card_id": c["id"]}
    # 无中生有
    for c in hand:
        if c["type"] == "INSTANT_TRICK" and c.get("subtype") == "draw_two":
            return {"card_id": c["id"]}
    # 其余即时锦囊（过河拆桥/顺手牵羊/决斗/火攻等）
    for c in hand:
        if c["type"] == "INSTANT_TRICK": return {"card_id": c["id"]}
    return None

class BotRunner:
    def __init__(self, config, idx):
        self.config, self.idx = config, idx
        self.pids = [p["id"] for p in config["players"]]
        self.heroes = {p["id"]: p["hero"] for p in config["players"]}
        self.match_id, self.states, self.ended = "", {}, set()
        self.tokens, self.actions = {}, {p: 0 for p in self.pids}
        self.uid_map = {}
        self._last_action_ts = 0  # timestamp of last action sent
        self._state_gen = 0  # incremented on each new op_code 10

    async def run(self):
        start = time.time()
        try:
            await self._auth(int(start))
            await self._create_match()
            async with asyncio.timeout(MATCH_TIMEOUT):
                await self._play()
        except asyncio.TimeoutError:
            pass
        except Exception as e:
            print(f"[ERR] {self.idx}: {e}", file=sys.stderr)
            import traceback; traceback.print_exc(file=sys.stderr)
        finally:
            e = time.time() - start
            c = len(self.ended) < len(self.pids)
            return {"index": self.idx, "result": "完成" if not c else "超时",
                    "turns": max(self.actions.values()) if self.actions else 0,
                    "elapsed": round(e, 1), "crashed": c}

    async def _auth(self, ts):
        ah = base64.b64encode(f"{NAKAMA_KEY}:".encode()).decode()
        async with aiohttp.ClientSession() as sess:
            for pid in self.pids:
                try:
                    r = await sess.post(
                        f"http://{NAKAMA_HOST}:{NAKAMA_PORT}/v2/account/authenticate/device?create=true",
                        headers={"Content-Type": "application/json", "Authorization": f"Basic {ah}"},
                        json={"id": f"bot-{pid}-{ts}"})
                    r.raise_for_status()
                    self.tokens[pid] = (await r.json())["token"]
                except Exception as e:
                    raise RuntimeError(f"auth failed for {pid}: {e}")

    async def _create_match(self):
        mode = "identity" if len(self.pids) == 5 else "pvp"
        async with aiohttp.ClientSession() as sess:
            try:
                r = await sess.post(
                    f"http://{NAKAMA_HOST}:{NAKAMA_PORT}/v2/rpc/find_or_create_match",
                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.tokens[self.pids[0]]}"},
                    data=json.dumps({"mode": mode, "max_players": len(self.pids)}))
                r.raise_for_status()
                self.match_id = json.loads((await r.json())["payload"])["match_id"]
            except Exception as e:
                raise RuntimeError(f"create_match failed: {e}")

    async def _play(self):
        conns = {}
        for pid in self.pids:
            ws = await websockets.connect(f"ws://{NAKAMA_HOST}:{NAKAMA_PORT}/ws?token={self.tokens[pid]}")
            conns[pid] = ws
            await ws.send(json.dumps({"cid": f"j-{pid}", "match_join": {"match_id": self.match_id, "metadata": {"hero_id": self.heroes[pid]}}}))
            r = json.loads(await ws.recv())
            if "match" in r:
                nuid = r["match"].get("self", {}).get("user_id", "")
                if nuid: self.uid_map[nuid], self.uid_map[pid] = pid, nuid

        async def drain_all():
            for pid in self.pids:
                try:
                    while True:
                        msg = await asyncio.wait_for(conns[pid].recv(), timeout=0.05)
                        d = json.loads(msg)
                        if "match_data" in d:
                            md = d["match_data"]
                            op = int(md["op_code"])
                            pl = json.loads(base64.b64decode(md["data"]))
                            if op == 10:
                                self.states[pid] = pl
                                self._state_gen += 1
                                # 首次收到 state 时对比服务端实际分配的 hero 与请求值
                                actual = pl.get("me", {}).get("hero")
                                if actual and pid not in getattr(self, "_hero_checked", set()):
                                    if not hasattr(self, "_hero_checked"): self._hero_checked = set()
                                    self._hero_checked.add(pid)
                                    requested = self.heroes.get(pid)
                                    if actual != requested:
                                        print(f"  [{self.idx}] bot {pid[:6]} hero: 请求={requested} → 实际={actual} ⚠️",
                                              flush=True)
                            elif op == 30:
                                self.ended.add(pid)
                except asyncio.TimeoutError: pass
                except websockets.exceptions.ConnectionClosed: self.ended.add(pid)

        async def drain_until_state_change(timeout=5.0):
            """Drain WebSocket messages until a new op_code 10 arrives (state change detected)."""
            start_gen = self._state_gen
            deadline = time.time() + timeout
            while time.time() < deadline:
                for pid in self.pids:
                    try:
                        msg = await asyncio.wait_for(conns[pid].recv(), timeout=0.1)
                        d = json.loads(msg)
                        if "match_data" in d:
                            md = d["match_data"]
                            op = int(md["op_code"])
                            pl = json.loads(base64.b64decode(md["data"]))
                            if op == 10:
                                self.states[pid] = pl
                                self._state_gen += 1
                                return True  # state updated
                            elif op == 30:
                                self.ended.add(pid)
                        # op_code 11, 20, 105 etc: just drain
                    except asyncio.TimeoutError:
                        pass
                    except websockets.exceptions.ConnectionClosed:
                        self.ended.add(pid)
                if self._state_gen > start_gen:
                    return True
            return False

        for _ in range(50):
            await drain_all()
            if len(self.states) >= len(self.pids):
                break
            await asyncio.sleep(0.2)

        for outer in range(MAX_ITER):
            await drain_all()
            if len(self.ended) >= len(self.pids):
                break

            if outer % 50 == 0:
                hp_str = ",".join(f"{self.states.get(p,{}).get('me',{}).get('hero','?' )}:{self.states.get(p,{}).get('me',{}).get('hp','?')}" for p in self.pids)
                print(f"  [{self.idx}] iter={outer} hp=[{hp_str}] ended={len(self.ended)}/{len(self.pids)}", flush=True)

            acted = False
            for pid in self.pids:
                state = self.states.get(pid)
                if not state or pid in self.ended:
                    continue
                ws = conns[pid]
                muid = self.uid_map.get(pid, "")
                tuid = state.get("current_turn", "")
                is_turn = tuid == muid
                pending = state.get("pending")
                hand = state.get("me", {}).get("hand", [])
                my_hp = state.get("me", {}).get("hp", 0)

                # Skip dead players
                if my_hp <= 0:
                    continue

                # Handle pending: always send confirm=False via op_code 5
                # The server internally checks if player_id matches the expected responder
                if isinstance(pending, dict) and pending:
                    pt = pending.get("type", "")
                    # Defense/Rescue/AOE: non-turn player is typically the defender
                    # COUNTER/DUEL/TRICK_SELECT/etc: server checks internally
                    # Everyone sends confirm=False — server ignores wrong players
                    await ws.send(json.dumps({"match_data_send":{"match_id":self.match_id,"op_code":5,
                        "data":base64.b64encode(json.dumps({"confirm":False}).encode()).decode()}}))
                    self.actions[pid] += 1; acted = True
                    self._last_action_ts = time.time()
                    continue

                # Play card or end turn (only if it's my turn)
                if is_turn:
                    a = ai_choose(hand, state)
                    if a:
                        await ws.send(json.dumps({"match_data_send":{"match_id":self.match_id,"op_code":3,
                            "data":base64.b64encode(json.dumps(a).encode()).decode()}}))
                    else:
                        await ws.send(json.dumps({"match_data_send":{"match_id":self.match_id,"op_code":4,
                            "data":base64.b64encode(json.dumps({}).encode()).decode()}}))
                    self.actions[pid] += 1; acted = True

            if acted:
                # After acting, wait for state to actually change before next iteration
                # This prevents infinite loops when server broadcasts rescue via op_code 11 only
                state_updated = await drain_until_state_change(timeout=5.0)
                if not state_updated:
                    await asyncio.sleep(0.5)
            else:
                await asyncio.sleep(0.1)

        for ws in conns.values():
            try: await ws.close()
            except: pass

async def admin_setup():
    """设置全英雄限时免费活动（需服务器 HTTP Key）。一次调用，全局生效。"""
    ah = base64.b64encode(f"{NAKAMA_KEY}:".encode()).decode()
    all_heroes = [
        "aladdin","alibaba","saladin","hakim","scheherazade","jafar",
        "ibn_battuta","al_khwarizmi","avicenna","sinbad","hulagu","rumi",
        "zubaydah","al_biruni","tamerlane","dunyazad","antar","nefertiti",
        "harun_al_rashid","suleiman","khayyam","zenobia","muawiyah","nizamulmulk",
        "enheduanna","al_mansur","gilgamesh","imru_al_qais","basira","dhul_qarnayn",
    ]
    now = int(time.time())
    payload = json.dumps({"heroes": all_heroes, "start_time": now, "end_time": now + 86400})
    async with aiohttp.ClientSession() as sess:
        r = await sess.post(
            f"http://{NAKAMA_HOST}:{NAKAMA_PORT}/v2/rpc/admin_set_free_event",
            headers={"Authorization": f"Basic {ah}", "Content-Type": "application/json"},
            data=payload)
        result = await r.json()
        if result.get("success"):
            print(f"admin_setup: OK, {len(all_heroes)} 英雄限免至 {time.ctime(now + 86400)}")
        else:
            print(f"admin_setup: FAIL {result} (可能已有活动存在，继续...)")

async def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--all", action="store_true")
    p.add_argument("--rounds", type=int, default=2)
    p.add_argument("--identity", action="store_true")
    p.add_argument("--skip-admin-setup", action="store_true", help="跳过管理员设置（已手动设置时使用）")
    args = p.parse_args()

    if not args.skip_admin_setup:
        await admin_setup()

    configs = MATCH_CONFIGS[14:] if args.identity else (MATCH_CONFIGS if args.all else MATCH_CONFIGS[:args.rounds])
    print(f"Asura Test: {len(configs)} matches")
    results = []
    for i, cfg in enumerate(configs):
        r = await BotRunner(cfg, i + 1).run()
        results.append(r)
        print(f"  {r['index']:02d}  {r['elapsed']:5.1f}s  {r['turns']:3d}回  {'✓' if not r['crashed'] else '✗'}")
        if i < len(configs) - 1: await asyncio.sleep(3)
    passed = sum(1 for r in results if not r["crashed"])
    print(f"{passed}/{len(configs)}  {'PASS' if passed == len(configs) else f'{len(configs) - passed} TIMEOUT'}")

if __name__ == "__main__":
    asyncio.run(main())
