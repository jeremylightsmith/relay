---
name: gen-problem
description: Use when creating a new problem statement file in docs/problems/. Guides through collecting the problem title, context, and expected outcomes, then writes the dated markdown file.
---

# Generate Problem File

## Overview

Guides through capturing a product problem and writes it as a dated file in `docs/problems/`.

## Workflow

### Step 1: Ask the user three questions

Use `AskUserQuestion` to collect all three at once:

1. **Problem title** — A short phrase completing "Coaches/users cannot…" (e.g. "track clients through acquisition stages in one CRM view")
2. **Context** — What does the person want to do? What exists today that falls short? What makes this painful? (2–4 sentences)
3. **Expected outcomes** — What should be true when solved? Ask for 3–5 bullet points.

### Step 2: Derive the filename

- Date prefix: today's date (`currentDate` from context), format `YYYY-MM-DD`
- Slug: kebab-case from the problem title (lowercase, hyphens, no special chars, strip "coaches cannot" prefix if present)
- Full path: `docs/problems/YYYY-MM-DD-slug.md`

### Step 3: Write the file using this exact template

```markdown
# Problems

## [Full sentence: what coaches/users cannot do]

Observed: YYYY-MM-DD

[Context paragraph]

Expected:

- [outcome 1]
- [outcome 2]
- [outcome 3]
```

### Step 4: Confirm

Report the file path that was created.

## Example

File: `docs/problems/2026-06-11-coaches-cannot-see-overall-pipeline.md`

```markdown
# Problems

## Coaches cannot see the overall client pipeline in a single view

Observed: 2026-06-11

A coach wants to see all prospective and current clients in one place with their acquisition stage visible at a glance. Today there is no consolidated view, so coaches must open individual records to understand pipeline status. This makes it hard to spot bottlenecks or prioritize follow-ups.

Expected:

- Coaches can see all clients listed in a single pipeline view.
- Each client displays their current acquisition stage.
- Coaches can filter or sort by stage.
```
