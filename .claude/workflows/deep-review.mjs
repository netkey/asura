export const meta = {
    name: "deep-review",
    description: "全项目深度 code review + 安全审查。产出修复计划供审批，不直接修改代码",
    phases: ["code-review", "security", "plan", "report"]
}

phase("code-review", () => {
    parallel(
        agent(`Review match_handler.lua for bugs. Focus on:
1. State machine: any path where pending_action is cleared without broadcast_update
2. Race conditions: any window where two players can interleave actions corrupting state
3. Missing nil checks on state.players[uid] after player death/disconnect
4. Loop logic: any "for/while" that can infinite-loop or skip valid items
5. Off-by-one: array index errors on hand/discard_pile/deck manipulation
6. Resource leaks: growing tables without cleanup (battle_log, pending_actions stack)
7. Return value dropped: calling hero_mgr.trigger() or rules.* functions and ignoring the result`),

        agent(`Review heroes/*.lua for bugs. Check every file implementing on_response:
1. Does every return path call broadcast_update? If a return exists without broadcast_update before it, the client hangs
2. Does the function clear pending_action only after confirming it's the right type/player?
3. Are payload fields validated with type() before use?
4. Any field access on potentially-nil state.players[uid]?
5. Any "for ... break" that looks like it meant "goto continue" (seen[xxx] filter pattern)
6. Any skill that stores state in state.* without a cleanup on skill cancel/timeout`),

        agent(`Review api.lua for bugs:
1. Check every RPC function for missing input validation (type/range/ownership checks)
2. Check for SQL injection in any string concatenation with user input
3. Check for OCC (optimistic concurrency control) version handling in storage writes
4. Check any function that operates on another player's data without authorization check
5. Check for dead code or unreachable branches`),

        agent(`Review game_rules.lua for bugs:
1. Turn phase transitions: can a phase transition fire twice or skip?
2. Death/damage resolution: is there a path where a dead player's pending_action stays alive?
3. Card movement: can a card exist in two places at once (hand + discard_pile) due to reference?
4. Deck reshuffle: what happens when deck is empty mid-draw and discard_pile is also empty?
5. Identity role win conditions: are all 5-player role win/loss conditions correct?
6. Any infinite loop in the damage chain (damage → trigger → damage → ...)`)
    )
})

phase("security", () => {
    parallel(
        agent(`Security review of api.lua:
1. Are ALL nk.register_rpc wrapped in safe_rpc()? List the line numbers if not
2. Is there any RPC that lets one player modify another player's storage/gold/inventory?
3. Are admin RPCs (admin_grant_gold, admin_set_config, etc.) properly access-controlled?
4. Are there any hardcoded secrets or tokens in the codebase?
5. Check nk.storage_write calls: do they all use OCC version from the preceding nk.storage_read?`),

        agent(`Security review of match_handler.lua and hero_manager.lua:
1. Can a player inject arbitrary state via payload to on_response?
2. Is there any eval/loadstring with user input?
3. Can a disconnected player's pending_action block the game forever?
4. Are all broadcast_messages to specific players scoped correctly (not leaking info)?`),

        agent(`Check the full codebase for:
1. loadstring, dofile, require with user-controllable path
2. nk.json_decode on unvalidated input without pcall
3. Any debug/backdoor code (demo*.lua, test endpoints that bypass auth)
4. Rate limiting: are all public RPCs rate-limited?`)
    )
})

phase("plan", () => {
    pipeline(
        agent(`Collect all findings from the code-review and security phases. For each finding:
- Assign a severity (P0/P1/P2/P3)
- Determine the exact file path and line number
- Describe the root cause
- Write the exact code change needed to fix it (old → new)
- Note any risks or side effects of the fix

Output a structured markdown file to .claude/workflows/fix-plan.md with sections:
- P0 (crash/data loss): list with exact fixes
- P1 (game hangs/wrong state): list with exact fixes
- P2 (validation missing): list with exact fixes
- P3 (defensive/style): list with exact fixes
- Summary stats: total bugs, severity breakdown, estimated fix complexity`),

        agent(`Verify each proposed fix by examining the actual source code. For each proposed fix in the plan:
1. Read the relevant source code section to confirm the bug exists
2. Verify the proposed fix is correct (no new bugs introduced)
3. Check if fixing one bug could mask another
4. Note any edge cases the fix doesn't cover

Output a review section at the bottom of .claude/workflows/fix-plan.md with "approved" or "needs discussion" for each fix.`)
    )
})

phase("report", () => {
    parallel(
        agent("Run luacheck --no-color . and report warning count alongside known state."),
        agent(`Summarize everything in a structured report:
1. Code review findings: number of bugs per category, top severity items
2. Security findings: vulnerabilities, missing controls
3. Fix plan summary: how many fixes proposed, P0/P1/P2/P3 breakdown
4. Next steps: how to approve and execute the fix plan
5. Recommendations: architectural improvements, testing gaps`)
    )
})
