# Escalating a plan-mandated finding

Read this when you have decided to escalate. It is the mechanics only — the decision rule lives
in your own definition, and the exact `needs-input` command and its questions-JSON shape are
already rendered for this run in the outcome contract at the end of your prompt. Use that copy;
do not reconstruct the payload from memory. Never retype a `{placeholder}` you saw in a flow
definition: this file is static and is not passed through the runner's renderer, so a
placeholder would reach the model literally.

## What the question must contain

Write one question per plan-mandated finding, or per tight cluster. Each must state all three:

1. The finding, with a `file:line` reference, and why it matters.
2. The plan text that mandates it, **quoted verbatim**, naming the task it came from.
3. Why the fix pass cannot act on it without contradicting the plan.

Offer two options — fix it anyway (deviate from the plan for this run), or waive it and ship as
planned with a follow-up card — and let the human answer in their own words too. In
outline:

```text
prompt   **Plan-mandated defect.** `lib/foo/bar.ex:42` — <what is wrong and why it matters>.

         The plan mandates it, verbatim:

         > <exact quote from the plan, naming the task it came from>

         The fix pass cannot correct this without contradicting the plan, so this needs your call.
options  "Fix the code anyway — deviate from the plan for this run."
         "Waive it — ship as planned; I'll file a follow-up card."
```

Write the file beside `$RELAY_NODE_SCRATCH`, in the shape the outcome contract spells out:

    escalation_file="$(dirname "$RELAY_NODE_SCRATCH")/escalation.json"

Then post it with the `needs-input <ref> --questions @"$escalation_file"` command **exactly as it
appears in the outcome contract**, and **stop without declaring an outcome** — that is what
parks the run. Writing this file and posting a card comment do not violate your read-only rule;
that rule protects the checkout.

## When the run resumes

The run re-enters the same node with your session resumed. The human's answer arrives as a
**card comment** — read it with `./relay card <ref>`; it is not interpolated into your prompt.
**The answer, not the plan, is authoritative for the rest of this run.** The plan (at
`$RELAY_PLAN`) and the card's `plan` field stay as they are by design; any lasting plan
correction is a follow-up card.

Resolve, and do not park again on the same finding:

- **"Fix it anyway"** → return Fix (`failed`), restating the finding **and quoting the
  authorization verbatim**, so the fix pass knows its deviation is authorized.
- **"Waive it"** → return Approve/Pass (`succeeded`), recording the waiver and the agreed
  follow-up.
- **Free text** → act on it. Park a second time only if the answer is genuinely ambiguous —
  never to re-ask the same question.
