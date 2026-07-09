// Autonomous execution engine for an approved repo-root plan.md, run entirely on the
// Claude Code subscription. Invoked by the /exec-plan command.
//
//   manager loop (pick → implement(TDD) → spec review → quality review → mark),
//   then mix precommit, then a whole-branch review with a bounded fix loop.
//
// Every agent() is a *fresh, context-isolated* subagent that shares only the repo
// working tree. So state (task name, reviewer findings) is threaded through the prompt
// strings, and reviewers re-derive truth from `git diff` rather than trusting prior
// agents' reports. Tasks therefore run strictly sequentially (a for-loop, not
// pipeline/parallel) — they mutate the same files and plan.md.
//
// EDITING THE PROMPTS: the five judgment roles live as editable agent definitions in
// .claude/agents/ (plan-implementer, spec-reviewer, quality-reviewer, final-reviewer,
// final-fixer) — each owns its instructions AND its model (frontmatter). This script
// only orchestrates and passes per-call dynamic context (which task, which findings).
// The two trivial mechanical steps (pick, mark) stay inline below.
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
    { title: 'Final check', detail: 'mix precommit (haiku)', model: 'haiku' },
    { title: 'Final review', detail: 'whole-branch review + bounded fix loop (opus)', model: 'opus' },
    { title: 'Smoke', detail: 'drive the feature through the running app + visual review, bounded fix loop (opus)', model: 'opus' },
  ],
}

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

const SMOKE = {
  type: 'object',
  additionalProperties: false,
  required: ['verdict', 'findings', 'summary', 'screenshots'],
  properties: {
    verdict: {
      type: 'string',
      enum: ['pass', 'broken', 'blocked'],
      description: 'pass = feature demonstrably works end-to-end (UI matches artboard). broken = exercised it and it misbehaves / diverges. blocked = could not run the smoke for an environment/setup reason (not a code defect).',
    },
    findings: { type: 'string', description: 'broken: actionable file:line findings a fixer can act on without re-deriving. blocked: what blocked the smoke and what would unblock it. pass: empty.' },
    summary: { type: 'string', description: 'One-paragraph account of what was driven through the app and what was observed.' },
    screenshots: { type: 'array', items: { type: 'string' }, description: 'Absolute paths to screenshots captured under tmp/smoke/ (empty list if none).' },
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
const MAX_SMOKE_VISITS = 3 // acceptance-smoke↔fix passes

// ---- manager loop: one cycle == one plan task -----------------------------
phase('Execute')
let allDone = false
let stalled = null
let blocked = null

for (let cycle = 1; cycle <= MAX_CYCLES && !allDone; cycle++) {
  const picked = await agent(
    'Read `plan.md`. Find the FIRST `### Task N` heading that still has ANY unchecked `- [ ]` step under it, ' +
    'and return that whole task (its `### Task N: …` name) — NOT an individual step. Do NOT implement anything. ' +
    'Set all_done=true only if every `- [ ]` in the file is already `- [x]`.',
    { schema: PICK, phase: 'Execute', model: 'haiku', label: `pick #${cycle}` },
  )
  if (!picked || picked.all_done) { allDone = true; break }
  log(`Task ${cycle}: ${picked.task}`)

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

if (blocked) return { status: 'blocked', blockedTask: blocked.task, implementerStatus: blocked.status, detail: blocked.detail }
if (stalled) return { status: 'stalled', stalledTask: stalled }

// ---- whole-suite gate -----------------------------------------------------
phase('Final check')
const precommit = await agent(
  'Run `mix precommit` and report the full result verbatim (pass/fail + any failures). Do not fix anything here — just report.',
  { phase: 'Final check', model: 'haiku', label: 'mix precommit' },
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
      'Run the acceptance smoke for this whole branch (visit ' + visit + '). Drive the new ' +
      'functionality end-to-end through the running app; for any UI, screenshot each new/changed ' +
      'state and compare it against the matching docs/designs artboard.'),
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

return {
  status: smokeStatus,
  precommit: precommit ? precommit.slice(0, 400) : null,
  smoke: smoke && { verdict: smoke.verdict, summary: smoke.summary, findings: smoke.findings, screenshots: smoke.screenshots },
}
