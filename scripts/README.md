# scripts/

Copy-paste helpers for one-off operational work — the kind of thing you'd otherwise
write from scratch in an IEx session, lose, and rewrite next month. This directory is
where they go so there's somewhere to look first.

**These are not application code.** Nothing here is compiled into the app, called by it,
or covered by tests. They are kept formatted (`mix format` includes `scripts/`), but
`credo` and `boundary` do not apply.

## Using one

Open a console and paste the file's contents in:

```sh
iex -S mix                                    # local
fly ssh console -a relayboard                 # prod…
/app/bin/relay remote                         # …then attach to the running node
```

Each script defines a module with its usage in `@moduledoc` and `@doc`. Read that first —
several of these touch production data.

## What's here

| Script | What it does |
| --- | --- |
| [`delete_user.exs`](delete_user.exs) | Delete a user, after reporting exactly what the delete would cascade to. Refuses to delete a board owner unless forced, because `boards.owner_id` is `on_delete: :delete_all` — deleting an owner destroys the whole board. |

## Adding one

Keep the shape consistent: one module, a `@moduledoc` that says how to run it, and — for
anything destructive — a dry-run function that reports before a separate function commits.
Prefer refusing by default and making the caller pass `force: true`.
