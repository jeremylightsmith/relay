# MMF 16 — AI result & sub-tasks in the drawer
**Milestone:** Post-MVP   **Depends on:** 04
**Design:** drawer AI RESULT (paragraphs/checks/screenshots) + SUB-TASKS checklist (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
Gives the AI a structured place to show its work — a written result with checkmarks and
screenshots, plus a sub-task checklist with progress — so a human can review at a glance.

## In scope
- `AI RESULT` block on a card: structured content (paragraphs, check items, image refs) the
  API can write (MMF 09) and the drawer renders.
- `SUB-TASKS`: a checklist (items with done/undone) + progress count; check/uncheck in the UI
  and via API.
- Screenshot/image attachments referenced from the result.

## Out of scope
- Full file/upload management — later. Rich text editing of results — keep render + API-write.

## Acceptance criteria
- [ ] A card can hold an AI-result block that renders in the drawer.
- [ ] Sub-tasks render with progress; toggling one updates the count and persists.
- [ ] Results/sub-tasks are writable via the API so the agent populates them.

## Notes
- Store result as structured JSON so both API and UI share one shape; images by URL/ref.
