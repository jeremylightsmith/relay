// Autonomous execution engine for an approved repo-root plan.md, run entirely on the
// Claude Code subscription. Invoked by the /exec-plan command.
//
//   manager loop (pick → sync→origin/main → implement(TDD) → spec review → quality review → mark),
//   then mix precommit, then a whole-branch review with a bounded fix loop, then an acceptance
//   smoke, then the card's own acceptance criteria — each with a bounded fix loop.
//
// Each cycle first keeps the branch current with origin/main: a cheap haiku `sync` agent
// detects drift (a no-op in the common case) and only on a real conflict spawns a sonnet
// `rebaser` agent to resolve it; if that can't be done safely the run halts with status
// "rebase-conflict" and the branch is left un-mangled (rebase aborted).
//
// Every agent() is a *fresh, context-isolated* subagent that shares only the repo
// working tree. So state (task name, reviewer findings) is threaded through the prompt
// strings, and reviewers re-derive truth from `git diff` rather than trusting prior
// agents' reports. Tasks therefore run strictly sequentially (a for-loop, not
// pipeline/parallel) — they mutate the same files and plan.md.
//
// EDITING THE PROMPTS: the judgment roles live as editable agent definitions in
// .claude/agents/ (plan-implementer, spec-reviewer, quality-reviewer, final-reviewer,
// final-fixer, smoke-tester, acceptance-tester) — each owns its instructions AND its model
// (frontmatter). This script only orchestrates and passes per-call dynamic context (which
// task, which findings, which card ref).
//
// Run it (requires an approved plan.md at the repo root, and your opt-in) via /exec-plan,
// or directly: Workflow({scriptPath: ".claude/workflows/execute-plan.js"}).

export const meta = {
  name: 'execute-plan',
  description: 'Execute an approved plan.md task-by-task: TDD, sequential spec then quality review, commit each; then precommit + whole-branch review.',
  whenToUse: 'After brainstorm + write-plan have produced an approved plan.md at the repo root.',
  phases: [
    { title: 'Execute', detail: 'pick next unchecked task / mark complete (haiku)', model: 'haiku' },
    { title: 'Implement', detail: 'TDD implement (sonnet, high effort)', model: 'sonnet' },
    { title: 'Spec review', detail: 'nothing missing / nothing extra (sonnet)', model: 'sonnet' },
    { title: 'Quality review', detail: 'well-built? (opus)', model: 'opus' },
    { title: 'Final check', detail: 'plan-declared gate, default mix precommit (haiku)', model: 'haiku' },
    { title: 'Final review', detail: 'whole-branch review + bounded fix loop (opus)', model: 'opus' },
    { title: 'Smoke', detail: 'drive the feature through the running app + visual review, bounded fix loop (opus)', model: 'opus' },
    { title: 'Acceptance', detail: 'run the card acceptance criteria, bounded fix loop (opus)', model: 'opus' },
    { title: 'Post', detail: 'acceptance checklist + smoke screenshots as one card comment (sonnet)', model: 'sonnet' },
  ],
}

// `args` can arrive JSON-encoded rather than as an object (notably via a resume, where
// the recovery hint stringifies it). Everything downstream reads `input.ref`, and a
// string has no `.ref` — which silently skipped the whole acceptance gate while the run
// still reported `ready`. Normalize once here so that can't fail open again.
const input = typeof args === 'string' ? JSON.parse(args) : args

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['pass', 'findings'],
  properties: {
    pass: { type: 'boolean', description: 'true = Pass/Approve, false = Fix' },
    findings: { type: 'string', description: 'If Fix: precise file:line findings the implementer can act on without guessing. If Pass: empty.' },
  },
}

const PICK = {
  type: 'object',
  additionalProperties: false,
  required: ['all_done', 'task'],
  properties: {
    all_done: { type: 'boolean', description: 'true when every checkbox in plan.md is [x]' },
    task: { type: 'string', description: 'The "### Task N: …" heading of the first task with any unchecked step, or "" when all_done' },
  },
}

const IMPL = {
  type: 'object',
  additionalProperties: false,
  required: ['status', 'detail'],
  properties: {
    status: {
      type: 'string',
      enum: ['DONE', 'DONE_WITH_CONCERNS', 'BLOCKED', 'NEEDS_CONTEXT'],
      description: 'DONE/DONE_WITH_CONCERNS = work committed (proceed to review). BLOCKED/NEEDS_CONTEXT = could not complete; the run halts so a human can intervene.',
    },
    detail: {
      type: 'string',
      description: 'If BLOCKED/NEEDS_CONTEXT: specifically what is blocking, what was tried, and what would unblock. Else: one-line test/precommit summary plus any concerns.',
    },
  },
}

const SYNC = {
  type: 'object',
  additionalProperties: false,
  required: ['result', 'detail'],
  properties: {
    result: {
      type: 'string',
      enum: ['clean', 'conflict', 'skip'],
      description: 'clean = branch is current with origin/main (no-op or clean rebase). conflict = a rebase would conflict (aborted; rebaser must resolve). skip = could not fetch (offline / no remote); sync skipped, run proceeds.',
    },
    detail: {
      type: 'string',
      description: 'On conflict: the conflicting file list + short summary (or the fact that uncommitted tracked changes were present). Else: one-line note.',
    },
  },
}

const SMOKE = {
  type: 'object',
  additionalProperties: false,
  // Only `verdict` is required: a passing smoke has no findings to report, and every
  // consumer below already null-guards the rest. Requiring all four made the agent
  // thrash the retry cap re-emitting a long summary just to satisfy a field it had
  // correctly left empty.
  required: ['verdict'],
  properties: {
    verdict: {
      type: 'string',
      enum: ['pass', 'broken', 'blocked'],
      description: 'pass = feature demonstrably works end-to-end (UI matches artboard). broken = exercised it and it misbehaves / diverges. blocked = could not run the smoke for an environment/setup reason (not a code defect).',
    },
    findings: { type: 'string', description: 'broken: actionable file:line findings a fixer can act on without re-deriving. blocked: what blocked the smoke and what would unblock it. pass: omit or empty.' },
    summary: { type: 'string', description: 'A few sentences on what was driven through the app and what was observed. Keep it short — this is a report field, not a transcript.' },
    screenshots: { type: 'array', items: { type: 'string' }, description: 'Absolute paths to screenshots captured under tmp/smoke/ (empty list if none).' },
  },
}

const CRITERIA = {
  type: 'object',
  additionalProperties: false,
  required: ['result', 'detail'],
  properties: {
    result: {
      type: 'string',
      enum: ['present', 'absent', 'error'],
      description:
        'present = the card fetch succeeded and acceptance_criteria is non-empty. absent = the fetch ' +
        'succeeded and it is empty (a pre-RLY-108 card, or none authored). error = the fetch ITSELF ' +
        'failed (non-zero exit from ./bin/relay, e.g. 404 / API down / expired key) — this is not the ' +
        'same as absent and must never be treated as "no criteria".',
    },
    detail: { type: 'string', description: 'One line: how many criteria were found, or why the fetch failed.' },
  },
}

const ACCEPTANCE = {
  type: 'object',
  additionalProperties: false,
  // Only `verdict` and `criteria` are required — a passing run has no findings, and the
  // per-criterion checklist is this stage's real payload. See SMOKE above: requiring a
  // field the agent is told to leave empty burns the StructuredOutput retry cap.
  required: ['verdict', 'criteria'],
  properties: {
    verdict: {
      type: 'string',
      enum: ['pass', 'fail', 'blocked'],
      description: 'pass = every criterion is pass or human-verify. fail = at least one criterion failed. blocked = the criteria could not be fetched or the environment prevented the whole run (not a code defect).',
    },
    summary: { type: 'string', description: 'A few sentences on what was run against the criteria. Keep it short — a report field, not a transcript.' },
    findings: { type: 'string', description: 'fail: actionable findings a fixer can act on without re-deriving. blocked: what blocked the run and what would unblock it. pass: omit or empty.' },
    criteria: {
      type: 'array',
      description: 'One entry per authored criterion, in the card order.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'title', 'result', 'evidence'],
        properties: {
          id: { type: 'string', description: "The criterion's number as authored, e.g. \"1\"." },
          title: { type: 'string', description: "The criterion's short title." },
          result: { type: 'string', enum: ['pass', 'fail', 'human-verify'], description: 'pass = expectation observed. fail = executed, expectation not met. human-verify = could not be executed/judged here.' },
          evidence: { type: 'string', description: 'pass: what was done and seen. fail: what happened instead. human-verify: why it could not be checked.' },
        },
      },
    },
  },
}

// The specialized role instructions live in .claude/agents/*.md, but those custom agent
// types are not registered in this session, so we run each role on `general-purpose` and
// have it adopt its role file as instructions. Models are set explicitly per call below.
const role = (name, body) =>
  `Operate as the "${name}" role for this project. FIRST read \`.claude/agents/${name}.md\` ` +
  `and follow it as your COMPLETE operating instructions (disregard its YAML frontmatter's ` +
  `tools/model — those are handled here). Note: this repo's toolchain runs through mise; ` +
  `bare \`mix\`/\`elixir\`/\`iex\` work (shimmed). Then carry out this specific task:\n\n${body}`

const MAX_CYCLES = 50      // max plan tasks per run
const MAX_ATTEMPTS = 6     // implement↔review retries per task
const MAX_FINAL_VISITS = 3 // whole-branch review↔fix passes
const MAX_SMOKE_VISITS = 3  // acceptance-smoke↔fix passes
const MAX_ACCEPT_VISITS = 3 // acceptance-criteria↔fix passes

// ---- manager loop: one cycle == one plan task -----------------------------
phase('Execute')
let allDone = false
let stalled = null
let blocked = null
let rebaseConflict = null

for (let cycle = 1; cycle <= MAX_CYCLES && !allDone; cycle++) {
  const picked = await agent(
    'Read `plan.md`. Find the FIRST `### Task N` heading that still has ANY unchecked `- [ ]` step under it, ' +
    'and return that whole task (its `### Task N: …` name) — NOT an individual step. Do NOT implement anything. ' +
    'Set all_done=true only if every `- [ ]` in the file is already `- [x]`.',
    { schema: PICK, phase: 'Execute', model: 'haiku', label: `pick #${cycle}` },
  )
  if (!picked || picked.all_done) { allDone = true; break }
  log(`Task ${cycle}: ${picked.task}`)

  // --- keep the branch current with origin/main: cheap detect, escalate real conflicts ---
  // origin/main rarely moves between two tasks of one run, so the common case is one no-op
  // haiku call. Only a real conflict spawns the (sonnet) rebaser.
  const sync = await agent(
    'You are a mechanical git sync step for an autonomous feature branch. Keep this branch ' +
    'current with `origin/main`. Do EXACTLY this, in order, and NEVER resolve a conflict yourself:\n' +
    '1. `git fetch origin main` (best-effort). If it fails (offline / no remote), return result:"skip".\n' +
    '2. If `git rev-list HEAD..origin/main` is EMPTY (origin/main has no commits absent from HEAD), ' +
    'return result:"clean" and do nothing else — this is the overwhelmingly common case.\n' +
    '3. If `git status --porcelain` shows any uncommitted TRACKED changes, do NOT stash or guess: ' +
    'return result:"conflict" with that fact in detail.\n' +
    '4. Otherwise run `git rebase origin/main`. If it completes with no conflicts, return result:"clean".\n' +
    '5. On conflict, run `git rebase --abort` (leave the branch untouched) and return result:"conflict" ' +
    'with the conflicting file list + a short summary in detail.\n' +
    'You DETECT only — you never resolve. Return the structured result.',
    { schema: SYNC, phase: 'Execute', model: 'haiku', label: `sync #${cycle}` },
  )
  if (sync && sync.result === 'conflict') {
    const rebase = await agent(
      role('rebaser',
        'The cheap sync step detected a conflict rebasing this branch onto origin/main ' +
        '(already fetched). Detail from sync:\n' + (sync.detail || '(none)') +
        '\n\nPerform the rebase, resolve every conflict preserving both intents, and leave the ' +
        'branch green (`mix precommit`). If you cannot, `git rebase --abort` and report failure.'),
      { agentType: 'general-purpose', model: 'sonnet', schema: VERDICT, phase: 'Execute', effort: 'high', label: `rebase #${cycle}` },
    )
    if (!rebase || !rebase.pass) {
      rebaseConflict = { conflictTask: picked.task, detail: (rebase && rebase.findings) || 'Rebaser failed to return a verdict.' }
      log(`⛔ rebase-conflict before: ${picked.task}`)
      break
    }
  }

  // implement → spec → quality, looping back to implement on any Fix.
  // Prompts/models for these three live in .claude/agents/; we pass only dynamic context.
  let approved = false
  let feedback = ''
  for (let attempt = 1; attempt <= MAX_ATTEMPTS && !approved; attempt++) {
    const impl = await agent(
      role('plan-implementer',
        `Task to implement (from plan.md): ${picked.task}\n\n` +
        'Implement the ENTIRE task — every one of its `- [ ]` steps — with strict TDD, and commit. ' +
        'The steps are your internal checklist; do NOT stop after one.' +
        (feedback ? `\n\nYou were sent back by a reviewer. Address EVERY finding:\n${feedback}` : '')),
      { agentType: 'general-purpose', model: 'sonnet', schema: IMPL, phase: 'Implement', effort: 'high', label: `implement #${cycle}.${attempt}` },
    )
    // The implementer escalated — don't review a non-existent change; halt for a human.
    if (impl && (impl.status === 'BLOCKED' || impl.status === 'NEEDS_CONTEXT')) {
      blocked = { task: picked.task, status: impl.status, detail: impl.detail || '' }
      log(`⛔ ${impl.status} on: ${picked.task}`)
      break
    }

    const spec = await agent(
      role('spec-reviewer', `Task under review (from plan.md): ${picked.task}`),
      { agentType: 'general-purpose', model: 'sonnet', schema: VERDICT, phase: 'Spec review', effort: 'high', label: `spec #${cycle}.${attempt}` },
    )
    if (!spec || !spec.pass) { feedback = (spec && spec.findings) || 'Spec review failed to return a verdict.'; continue }

    const quality = await agent(
      role('quality-reviewer', `Task under review (from plan.md): ${picked.task}`),
      { agentType: 'general-purpose', model: 'opus', schema: VERDICT, phase: 'Quality review', effort: 'high', label: `quality #${cycle}.${attempt}` },
    )
    if (!quality || !quality.pass) { feedback = (quality && quality.findings) || 'Quality review failed to return a verdict.'; continue }

    approved = true
  }

  if (blocked) break
  if (!approved) { stalled = picked.task; log(`⚠ Task stuck after ${MAX_ATTEMPTS} attempts: ${picked.task}`); break }

  await agent(
    `In plan.md, change EVERY '- [ ]' step under this task's '### Task N' heading to '- [x]' (the whole task section). ` +
    `plan.md is a gitignored, throwaway working file: do NOT commit it and do NOT 'git add' it — progress is tracked in the working tree only. Change nothing else.\nTask: ${picked.task}`,
    { phase: 'Execute', model: 'haiku', label: `mark #${cycle}` },
  )
}

if (rebaseConflict) return { status: 'rebase-conflict', conflictTask: rebaseConflict.conflictTask, detail: rebaseConflict.detail }
if (blocked) return { status: 'blocked', blockedTask: blocked.task, implementerStatus: blocked.status, detail: blocked.detail }
if (stalled) return { status: 'stalled', stalledTask: stalled }

// ---- whole-suite gate -----------------------------------------------------
phase('Final check')
const precommit = await agent(
  'Run the plan\'s declared verification gate and report the full result verbatim (pass/fail + any failures). ' +
  'The gate is whatever plan.md\'s "## Verification" section specifies under **Gate:** — default `mix precommit` ' +
  'when that section is absent. (A Flutter-only card typically declares `flutter analyze` + `flutter test` run in ' +
  '`flutter/`, not `mix precommit`.) Do not fix anything here — just run the declared gate and report.',
  { phase: 'Final check', model: 'haiku', label: 'gate' },
)

// ---- cross-cutting whole-branch review with bounded fix loop --------------
// Prompts/models for both roles live in .claude/agents/.
phase('Final review')
let ready = false
for (let visit = 1; visit <= MAX_FINAL_VISITS && !ready; visit++) {
  const fr = await agent(
    role('final-reviewer', 'Review the whole branch now (visit ' + visit + ').'),
    { agentType: 'general-purpose', model: 'opus', schema: VERDICT, phase: 'Final review', effort: 'high', label: `final-review #${visit}` },
  )
  if (!fr || fr.pass) { ready = true; break }

  await agent(
    role('final-fixer', 'Blocking findings from the whole-branch review — fix ALL of them in one pass:\n' + fr.findings),
    { agentType: 'general-purpose', model: 'sonnet', phase: 'Final review', effort: 'high', label: `final-fix #${visit}` },
  )
}

if (!ready) {
  return { status: 'review-loop-exhausted', precommit: precommit ? precommit.slice(0, 400) : null }
}

// ---- acceptance smoke: drive the feature through the running app (+ visual) --
// Always runs once the branch is assembled and green. broken → fix and re-smoke
// (bounded); blocked is an environment/setup problem, not a code defect, so it is
// reported without fix-looping.
phase('Smoke')
let smoke = null
for (let visit = 1; visit <= MAX_SMOKE_VISITS; visit++) {
  smoke = await agent(
    role('smoke-tester',
      'Run the acceptance smoke for this whole branch (visit ' + visit + '). Follow plan.md\'s "## Verification" ' +
      '**Smoke:** directive if present (e.g. a Flutter card boots the app in the iOS simulator and screenshots each ' +
      'state); otherwise drive the new functionality end-to-end through the running web app. For any UI, screenshot ' +
      'each new/changed state and compare it against the matching docs/designs artboard.'),
    { agentType: 'general-purpose', model: 'opus', schema: SMOKE, phase: 'Smoke', effort: 'high', label: `smoke #${visit}` },
  )
  if (!smoke || smoke.verdict === 'pass') break
  if (smoke.verdict === 'blocked') break // infra/setup — don't fix-loop an environment problem

  await agent(
    role('final-fixer', 'The acceptance smoke found the feature broken end-to-end — fix ALL of it in one pass:\n' + (smoke.findings || '')),
    { agentType: 'general-purpose', model: 'sonnet', phase: 'Smoke', effort: 'high', label: `smoke-fix #${visit}` },
  )
}

const smokeStatus =
  smoke && smoke.verdict === 'pass' ? 'ready' :
  smoke && smoke.verdict === 'blocked' ? 'smoke-blocked' :
  'smoke-failed'

// ---- acceptance: run the card's human-authored criteria (RLY-108) ---------
// The criteria live on the card, never in plan.md, so a cheap haiku probe fetches
// them first: an empty/absent field is a no-op (a pre-RLY-108 card still reaches
// `ready`), not an error. Runs only after a passing smoke — a branch that already
// failed smoke has nothing to accept — and only with a card ref to read from.
let acceptance = null
let acceptanceRan = false

if (smokeStatus === 'ready' && input && input.ref) {
  phase('Acceptance')
  const probe = await agent(
    `Read Relay card ${input.ref}'s acceptance criteria and report ONLY whether it has any — do NOT ` +
      `run the criteria, edit anything, or touch the card. This repo has a CLI at ./bin/relay and ` +
      `RELAY_URL + RELAY_API_KEY are already set. Run \`./bin/relay card ${input.ref} --json\` ON ITS ` +
      `OWN first (not through a pipe) and check ITS OWN exit status, separately from anything ` +
      `downstream. On a non-zero exit (404 / API down / expired key / bogus ref — the CLI writes the ` +
      `error to stderr and prints NOTHING to stdout), return result="error" with the stderr text in ` +
      `detail. An error is NOT the same as an empty field — never report "absent" when the fetch ` +
      `itself failed. Only once you've confirmed a zero exit, pipe that same JSON through ` +
      `\`jq -r '.acceptance_criteria // ""'\` and return result="present" when it prints non-whitespace ` +
      `text, result="absent" when it is empty.`,
    { schema: CRITERIA, phase: 'Acceptance', model: 'haiku', label: 'criteria probe' },
  )

  if (probe && probe.result === 'present') {
    acceptanceRan = true

    for (let visit = 1; visit <= MAX_ACCEPT_VISITS; visit++) {
      acceptance = await agent(
        role('acceptance-tester',
          `Card ref: ${input.ref} (visit ${visit}). Read its acceptance criteria off the card and run ` +
          `every one of them against this branch.\n\nThe smoke-tester already drove this branch ` +
          `end-to-end. Its evidence — judge from it rather than re-driving anything it already ` +
          `settles:\n` +
          `- verdict: ${smoke.verdict}\n` +
          `- summary: ${smoke.summary || '(none)'}\n` +
          `- findings: ${smoke.findings || '(none)'}\n` +
          `- screenshots:\n${(smoke.screenshots || []).map((s) => `   - ${s}`).join('\n') || '   (none)'}`),
        { agentType: 'general-purpose', model: 'opus', schema: ACCEPTANCE, phase: 'Acceptance', effort: 'high', label: `acceptance #${visit}` },
      )
      // pass/blocked both end the loop: blocked is an environment problem, not a code
      // defect, so it is reported without fix-looping (same rule as smoke).
      if (!acceptance || acceptance.verdict !== 'fail') break
      // Last visit: a fix here would never be re-tested, so don't spend it.
      if (visit === MAX_ACCEPT_VISITS) break

      await agent(
        role('final-fixer',
          'The acceptance criteria on this card failed — fix ALL of it in one pass:\n' + (acceptance.findings || '')),
        { agentType: 'general-purpose', model: 'sonnet', phase: 'Acceptance', effort: 'high', label: `accept-fix #${visit}` },
      )
    }
  } else if (!probe || probe.result === 'error') {
    // Fail CLOSED, not open: a probe that itself failed, or that couldn't fetch the
    // card, tells us nothing about whether criteria exist. Treating that the same as
    // "no criteria" would let a flaky API / bad ref silently skip enforcement and ship
    // a branch whose criteria were never run. Synthesize the same shape a real
    // acceptance-tester would return for an environment blocker, so it flows through
    // the existing verdict → finalStatus mapping below unchanged.
    acceptanceRan = true
    acceptance = {
      verdict: 'blocked',
      summary: '',
      findings: (probe && probe.detail) || 'The criteria probe failed to return a verdict.',
      criteria: [],
    }
    log(`Could not confirm acceptance criteria on ${input.ref} — treating as blocked: ${acceptance.findings}`)
  } else {
    log(`No acceptance criteria on ${input.ref} — skipping the acceptance phase. ${probe.detail || ''}`.trim())
  }
}

// Fail closed on a missing verdict (matching Smoke's ternary, not Final review's
// fail-open). When the phase did not run, the smoke status stands.
const finalStatus = !acceptanceRan
  ? smokeStatus
  : acceptance && acceptance.verdict === 'pass' ? 'ready'
  : acceptance && acceptance.verdict === 'blocked' ? 'acceptance-blocked'
  : 'acceptance-failed'

const RESULT_ICON = { pass: '✅', fail: '❌', 'human-verify': '👤' }

const acceptanceBlock = (() => {
  if (!acceptance || !Array.isArray(acceptance.criteria) || !acceptance.criteria.length) return ''
  const counts = acceptance.criteria.reduce((acc, c) => {
    acc[c.result] = (acc[c.result] || 0) + 1
    return acc
  }, {})
  const parts = []
  if (counts.pass) parts.push(`${counts.pass} passed`)
  if (counts.fail) parts.push(`${counts.fail} failed`)
  if (counts['human-verify']) parts.push(`${counts['human-verify']} human-verify`)
  const lines = acceptance.criteria
    .map((c, i) => `${i + 1}. ${RESULT_ICON[c.result] || '•'} **${c.title}** — ${c.evidence}`)
    .join('\n')
  return `## Acceptance — ${parts.join(' · ')}\n\n${lines}`
})()

// ---- post the acceptance checklist + smoke screenshots to the card -------
// ONE comment per run: the per-criterion checklist first (what a human reads at
// the review gate), then the smoke screenshots inline beneath. Fires whenever the
// card ref was threaded in via args AND there is something to report — an
// acceptance report or screenshots. No verdict gating: a failing run is exactly
// when the human most needs the report. `relay attach` + `relay comment` are the
// tested primitives; this glue is not unit-tested (consistent with the rest of the
// workflow orchestration). The agent posts a COMMENT and never a status change.
const shotPaths = (smoke && Array.isArray(smoke.screenshots) && smoke.screenshots) || []

if (input && input.ref && (acceptanceBlock || shotPaths.length)) {
  phase('Post')
  const shots = shotPaths.map((s) => `   - ${s}`).join('\n')
  const attachStep = shotPaths.length
    ? `1. For EACH screenshot path below, run \`./bin/relay attach ${input.ref} <path> --json\` and keep the ` +
      `"markdown" field it prints:\n${shots}\n`
    : `1. There are no screenshots to attach — skip straight to step 2.\n`
  const body = [acceptanceBlock, smoke && smoke.summary].filter(Boolean).join('\n\n') || 'Smoke results'

  await agent(
    `Post the acceptance + smoke results to Relay card ${input.ref}. This repo has a CLI at ./bin/relay ` +
      `and RELAY_URL + RELAY_API_KEY are already set in the environment. Do EXACTLY this and nothing else:\n` +
      attachStep +
      `2. Post ONE comment with \`./bin/relay comment ${input.ref} @<tmpfile>\` whose body is the text ` +
      `below, then a blank line, then the collected markdown snippets one per line (one image per ` +
      `new/changed state — do not add extras):\n\n${body}\n\n` +
      `Post at most ONE comment, VERBATIM — do not re-judge, re-word, or drop any criterion. Do NOT ` +
      `change the card's status, and do not touch git or any other card. Report what you posted.`,
    { agentType: 'general-purpose', model: 'sonnet', phase: 'Post', effort: 'low', label: 'post-results' },
  )
}

return {
  status: finalStatus,
  precommit: precommit ? precommit.slice(0, 400) : null,
  smoke: smoke && { verdict: smoke.verdict, summary: smoke.summary, findings: smoke.findings, screenshots: smoke.screenshots },
  acceptance: acceptance && { verdict: acceptance.verdict, summary: acceptance.summary, findings: acceptance.findings, criteria: acceptance.criteria },
}
