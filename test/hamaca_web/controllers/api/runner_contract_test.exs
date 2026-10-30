defmodule HamacaWeb.Api.RunnerContractTest do
  @moduledoc """
  The server↔runner contract (RLY-176).

  This test is the ONLY writer of `test/fixtures/runner_contract.json`. It drives the real
  `/api/node-jobs/*` routes, captures what they actually send and accept, and asserts the
  committed fixture still matches. `bin/test_relay.py` builds every job dict from that same
  file, so a field renamed here breaks the Python suite on the next run — which is the whole
  point: before this existed, both suites were green against their own imagination of the
  other (RLY-163/165/166/170/175).

  No payload literal is typed into this file. Regenerate with:

      RELAY_WRITE_CONTRACT_FIXTURE=1 mix test test/hamaca_web/controllers/api/runner_contract_test.exs

  which rewrites the fixture AND still fails, so a regenerated fixture cannot slip through
  unreviewed in the same run.
  """
  use HamacaWeb.ConnCase, async: true

  alias Hamaca.Flows.Shape
  alias Hamaca.Runs
  alias Hamaca.Runs.Audit
  alias Hamaca.Runs.FakeDispatcher
  alias Hamaca.Scaffold

  @fixture_path "test/fixtures/runner_contract.json"

  setup do
    FakeDispatcher.register(self())
    start_engine!()
    :ok
  end

  test "the committed fixture matches what /api/node-jobs/* actually sends and accepts" do
    user = insert(:user, name: "Test User")

    shared = board_with_flow(user, "Contract A", "CA", :shared_clean, agent_node())
    exclusive = board_with_flow(user, "Contract B", "CB", :exclusive, shell_node())

    # The heartbeat MUST run before anything is claimed: RLY-170's orphan recovery reads the
    # absence of a job from `running` as "this runner restarted and lost it" and requeues it,
    # which would yank the job out from under the claims below.
    heartbeat_request = %{
      "runner" => runner_ident(),
      "capacity" => %{"shared_clean" => 1, "exclusive" => 1},
      # RLY-182: optional, send-on-change. Present here so the fixture records the key
      # and its shape for bin/test_relay.py to build against.
      "capabilities" => %{"agents" => ["plan-implementer"], "skills" => ["write-plan"]},
      "running" => [],
      "held" => [],
      # RE358: optional, sent only when an in-flight agent job has captured a session — a
      # `{job-id-string => session-id}` map. Keyed by job id 0, which no board can own (ids are
      # serial from 1), so the server ignores the entry and the claims below are unaffected.
      "sessions" => %{"0" => "fixture-session"},
      # RE433: the per-harness inventory, sent on every beat once the runner has fetched
      # /api/harnesses. Claude Code installed, so the claims below are still offered.
      # RE436: each entry carries that harness's `usage` — its latest reading per window and
      # its pause, if any (here paused at 95% of a 90% 5h window). The top-level RE320
      # `rate_limit` is retired. Far-future epochs (2100-01-01) so the fixture never churns;
      # the server ignores `usage` until it stores per-harness readings.
      "harnesses" => [
        %{
          "key" => "claude-code",
          "installed" => true,
          "version" => "2.1.296 (Claude Code)",
          "signed_in" => true,
          "usage" => %{
            "source" => "output",
            "read_at" => 4_102_444_000,
            "windows" => [%{"label" => "5h", "used_pct" => 95.0, "resets_at" => 4_102_444_800}],
            "paused" => %{
              "label" => "5h",
              "used_pct" => 95.0,
              "pause_at" => 90,
              "resets_at" => 4_102_444_800,
              "reason" => "limit"
            }
          }
        }
      ]
    }

    heartbeat_response =
      shared.conn
      |> post(~p"/api/node-jobs/heartbeat", Jason.encode!(heartbeat_request))
      |> json_response(200)

    # 1. shared_clean_agent — the Spec/Plan shape. Its `vars` carry `branch` because
    #    build_payload sets it unconditionally; the mere existence of this case is what would
    #    have caught the RLY-166 guard.
    {run, shared_clean_agent} = claim_one(shared, %{"shared_clean" => 1})

    # 2. The outcome the runner POSTs, at the real controller. `needs_input` parks the run,
    #    which is also how we reach the resumed case below.
    outcome_request = %{
      "outcome" => "needs_input",
      "detail" => "asked the human",
      "git_sha" => "0000000000000000000000000000000000000000",
      "session_id" => "sess-fixture",
      # RE310: always sent, never omitted — this is the key set bin/test_relay.py pins
      # `outcome_body` against.
      "no_changes" => false,
      # RE267: optional — the runner sends it only for a usage-limit `blocked` with a known reset.
      # Present here so bin/test_relay.py pins its key and format; on this `needs_input` it is
      # ignored by design (read only on `blocked`), which this POST also proves is not a 422.
      "resume_at" => "2100-01-01T00:00:00Z"
    }

    outcome_response =
      shared.conn
      |> post(~p"/api/node-jobs/#{shared_clean_agent["id"]}/outcome", Jason.encode!(outcome_request))
      |> json_response(200)

    # 3. resumed_agent — re-entry populates resume_session, the one field no fresh claim shows.
    # `run` is the struct captured at claim time, before the needs_input outcome parked it —
    # resume_run/2 requires status: :parked, so it must be reloaded first.
    {:ok, _run} = run.id |> Runs.get_run!() |> Runs.resume_run(resume_session: "sess-fixture")
    assert_receive {:node_started, _run, _execution}, 2_000
    resumed_agent = claim(shared, %{"shared_clean" => 1})

    # 4. exclusive_shell — the Code shape.
    {_run, exclusive_shell} = claim_one(exclusive, %{"exclusive" => 1})

    # 5. talk — the person-dispatched shape. Claimed on the SAME endpoint, distinguished only
    #    by `kind`, which is the whole point of reusing `node_jobs` (ADR 0014).
    talk_author = user

    {:ok, talk_card} =
      Hamaca.Cards.create_card(exclusive.next_up, %{title: "Talk card", description: "Why is this stuck?"})

    {:ok, talk_turn} = Hamaca.Talk.post_message(talk_card, talk_author, "why is this stuck?")
    # RE366 — the talk card has no run and no runner holds it, so its turn is `shared_clean`
    # and needs free shared capacity (an exclusive talk turn still bypasses capacity).
    talk_job = claim(exclusive, %{"shared_clean" => 1})
    assert talk_job["isolation"] == "shared_clean"

    talk_events_request = %{
      "events" => [
        %{"client_seq" => 1, "kind" => "tool", "text" => "Read · lib/relay.ex", "dim" => true},
        %{"client_seq" => 2, "kind" => "out", "text" => "It is waiting on an open question.", "dim" => false}
      ]
    }

    talk_events_response =
      exclusive.conn
      |> post(~p"/api/talk/turns/#{talk_turn.id}/events", Jason.encode!(talk_events_request))
      |> json_response(200)

    talk_outcome_request = %{"status" => "done", "session_id" => "sess-fixture", "detail" => nil}

    talk_outcome_response =
      exclusive.conn
      |> post(~p"/api/talk/turns/#{talk_turn.id}/outcome", Jason.encode!(talk_outcome_request))
      |> json_response(200)

    # RE319 — the outdated refusal is wire too: ./relay branches on its `code` to tell a verdict
    # from a job, and a pre-rename process is answered with the same code. Captured off the real
    # claim route from a runner one below the floor, under its own name so the rows above are
    # untouched.
    outdated_body =
      put_in(claim_body(%{"shared_clean" => 1}), ["runner"], %{
        runner_ident()
        | "name" => "fixture-outdated",
          "version" => Runs.min_runner_version() - 1
      })

    outdated_refusal =
      shared.conn
      |> post(~p"/api/node-jobs/claim?wait=0", Jason.encode!(outdated_body))
      |> json_response(409)

    # RE460 — the plan_paused refusal is wire too: ./relay branches on its `code` to tell a
    # paused board from a job or a hard error. Captured off the real claim route from a third
    # board whose own owner is paused (held), with billing on only for this one request.
    paused_owner = insert(:user)
    paused = board_with_flow(paused_owner, "Contract P", "CP", :shared_clean, agent_node())
    insert(:billing_account, user: paused_owner, held_on: Date.utc_today(), hold_reason: "contract")

    Process.put(:billing_enabled, true)

    plan_paused_refusal =
      paused.conn
      |> post(~p"/api/node-jobs/claim?wait=0", Jason.encode!(claim_body(%{"shared_clean" => 1})))
      |> json_response(402)

    Process.delete(:billing_enabled)

    assert plan_paused_refusal == %{
             "error" => %{"code" => HamacaWeb.PlanPaused.code(), "message" => HamacaWeb.PlanPaused.message()}
           }

    # RE304: /api/scaffold is app↔runner wire now (`./relay update` reads it), so it is
    # pinned here like every other transport — a renamed key breaks CI instead of breaking a
    # project's bootstrap. Captured off the real route, unauthenticated like the runner's own
    # first call.
    scaffold_manifest = build_conn() |> get(~p"/api/scaffold") |> json_response(200)
    scaffold_manifest_hamaca = build_conn() |> get(~p"/api/scaffold?layout=hamaca") |> json_response(200)

    # RE355 — the card-task routes are runner wire: `./relay tasks add|list` and
    # `./relay task show|update|rm` build their requests and read their responses against these
    # recorded shapes, so a renamed key breaks bin/test_relay.py instead of an agent's plan.
    {:ok, tasks_card} = Hamaca.Cards.create_card(exclusive.next_up, %{title: "Tasks card"})
    tasks_ref = Hamaca.Cards.ref(exclusive.board, tasks_card)

    tasks_create_request = %{
      "tasks" => [
        %{"title" => "Schema", "body" => "Add the column.\n\n```elixir\nadd :body, :text\n```\n"},
        %{"title" => "Routes", "body" => "Say \"hello\" to the router.\n"}
      ]
    }

    tasks_create_response =
      exclusive.conn
      |> post(~p"/api/cards/#{tasks_ref}/tasks", Jason.encode!(tasks_create_request))
      |> json_response(201)

    [%{"id" => first_task_id}, %{"id" => second_task_id}] = tasks_create_response["data"]

    tasks_list_response = exclusive.conn |> get(~p"/api/cards/#{tasks_ref}/tasks") |> json_response(200)

    tasks_show_response =
      exclusive.conn |> get(~p"/api/cards/#{tasks_ref}/tasks/#{first_task_id}") |> json_response(200)

    tasks_update_request = %{"title" => "Routes (renamed)", "body" => "Renamed.\n"}

    tasks_update_response =
      exclusive.conn
      |> patch(~p"/api/cards/#{tasks_ref}/tasks/#{second_task_id}", Jason.encode!(tasks_update_request))
      |> json_response(200)

    tasks_delete_response =
      exclusive.conn |> delete(~p"/api/cards/#{tasks_ref}/tasks/#{first_task_id}") |> json_response(200)

    # RE370 — `./relay mockups` uploads each file through the attachments route, then PATCHes the
    # whole list in one call. Both ends are runner wire, so the request it builds and the list the
    # card hands back are pinned like the task routes.
    {:ok, mockups_card} = Hamaca.Cards.create_card(exclusive.next_up, %{title: "Mockups card"})
    mockups_ref = Hamaca.Cards.ref(exclusive.board, mockups_card)

    mockup_html = "<!doctype html><p>Empty</p>"

    mockup_upload = %{
      "filename" => "empty.html",
      "content_type" => Schemas.Attachment.html_type(),
      "data_base64" => Base.encode64(mockup_html)
    }

    %{"data" => %{"url" => mockup_url}} =
      exclusive.conn
      |> post(~p"/api/cards/#{mockups_ref}/attachments", Jason.encode!(mockup_upload))
      |> json_response(201)

    mockups_request = %{"mockups" => [%{"url" => mockup_url, "caption" => "Empty state"}]}

    mockups_response =
      exclusive.conn
      |> patch(~p"/api/cards/#{mockups_ref}", Jason.encode!(mockups_request))
      |> json_response(200)

    # RE373 — `relay mockups --pull` turns each mockup url into its download path and GETs the
    # raw bytes with the board key. The path comes from the one definition and is proven against
    # the real route here, so the url shape and the download route can never drift apart.
    {:ok, mockup_id} = Schemas.Attachment.id_from_path(mockup_url)
    assert exclusive.conn |> get(Schemas.Attachment.api_path(mockup_id)) |> response(200) == mockup_html

    # RE499 — `./hamaca mockups --add` uploads, then POSTs only the new entries to the append
    # path; `--remove` DELETEs one attachment id off the remove path. The recorded templates are
    # the ones these real routes answered, with the real ref / id substituted in.
    mockups_append_path = "/api/cards/<ref>/mockups"
    mockup_remove_path = "/api/cards/<ref>/mockups/<attachment-id>"

    %{"data" => %{"url" => variant_url}} =
      exclusive.conn
      |> post(
        ~p"/api/cards/#{mockups_ref}/attachments",
        Jason.encode!(%{mockup_upload | "filename" => "variant.html"})
      )
      |> json_response(201)

    {:ok, variant_id} = Schemas.Attachment.id_from_path(variant_url)
    mockups_append_request = %{"mockups" => [%{"url" => variant_url, "caption" => "Variant"}]}

    mockups_append_response =
      exclusive.conn
      |> post(
        String.replace(mockups_append_path, "<ref>", mockups_ref),
        Jason.encode!(mockups_append_request)
      )
      |> json_response(200)

    assert length(mockups_append_response["data"]["mockups"]) == 2

    mockup_remove_response =
      exclusive.conn
      |> delete(
        mockup_remove_path
        |> String.replace("<ref>", mockups_ref)
        |> String.replace("<attachment-id>", variant_id)
      )
      |> json_response(200)

    assert length(mockup_remove_response["data"]["mockups"]) == 1

    # RE384 — `./relay stages` / `./relay stage …` read stage objects off `/api/stages`; the key
    # set is recorded from the real route, never typed.
    [stage_object | _] = exclusive.conn |> get(~p"/api/stages") |> json_response(200) |> Map.fetch!("data")

    # RE433 — `./relay` fetches the harness definitions it expands off this route, at start and
    # whenever the heartbeat's `harnesses_digest` moves. Key sets recorded from the real route.
    harnesses_response = shared.conn |> get(~p"/api/harnesses") |> json_response(200)

    # RE430 — `./relay flow` / `stages` / `why` print a paused flow's What / Why / Fix verbatim
    # off the read-only `problem` object. An enabled flow on Deploy pulls from the main Review
    # stage (`:upstream_review`), a real paused flow — it never dispatches, so it cannot disturb
    # the claims above. Its key sets come from the real route.
    deploy = Enum.find(exclusive.board.stages, &(&1.name == "Deploy"))

    {:ok, paused} =
      Hamaca.Flows.create_flow(exclusive.board, %{
        key: "contract-paused",
        isolation: :shared_clean,
        stage_id: deploy.id,
        nodes: [agent_node()],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
      })

    {:ok, _paused} = Hamaca.Flows.enable_flow(paused)

    paused_problem =
      exclusive.conn |> get(~p"/api/flows/contract-paused") |> json_response(200) |> get_in(["data", "problem"])

    # RE429 — `./relay flow` prints `pulls_from → stage → lands_on` from a flow document's
    # one-key trigger and its read-only `derived` block; both key sets come from the real route.
    flow_doc = exclusive.conn |> get(~p"/api/flows/contract") |> json_response(200) |> Map.fetch!("data")

    # RE427 — `./relay card` prints each note image as an `[image]` line and `relay images --pull`
    # downloads it; both read these keys off a real comment entry, so record them from the route.
    {:ok, images_card} = Hamaca.Cards.create_card(exclusive.next_up, %{title: "Note images card"})
    images_ref = Hamaca.Cards.ref(exclusive.board, images_card)

    {:ok, note_image} =
      Hamaca.Attachments.create_attachment(images_card, %{
        filename: "shot.png",
        content_type: "image/png",
        bytes: "\x89PNG fixture"
      })

    {:ok, _note} =
      Hamaca.Activity.add_comment(images_card, %{
        actor: {:user, user.id},
        body: "see shot",
        image_ids: [note_image.id],
        # RE428 — an image note carries its origin; `./relay card` prints it after the author.
        origin: {:answer, 2}
      })

    note_entry =
      exclusive.conn
      |> get(~p"/api/cards/#{images_ref}")
      |> json_response(200)
      |> get_in(["data", "timeline"])
      |> Enum.find(&(&1["kind"] == "comment" and &1["images"] != []))

    [note_image_item] = note_entry["images"]

    # RE445 — `./relay setup status|report` read and move the setup checklist. Captured off the
    # real routes on a template board sitting on sub-step 5.1; the refusals off the same routes.
    setup = setup_capture(user, exclusive.conn)

    document = %{
      "version" => 15,
      # RE436 — the shared path/condition/reading cases both usage-rule evaluators must pass:
      # ExUnit runs them in test/hamaca/usage_rule_cases_test.exs, Python reads them from here.
      "usage_rule_cases" => Hamaca.UsageRuleCases.cases(),
      "note_images" => %{
        "comment_entry" => note_entry |> Map.keys() |> Enum.sort(),
        "image" => note_image_item |> Map.keys() |> Enum.sort(),
        # RE428 — the origin kinds `./relay card` prints; the one set is Schemas.Comment.origins/0.
        "origin_kinds" => Enum.map(Schemas.Comment.origins(), &Atom.to_string/1)
      },
      "mockups" => %{
        "download_path" => Schemas.Attachment.api_path("<attachment-id>"),
        # RE390 — what a mockup may be; `./relay`'s MOCKUP_TYPES values must equal it.
        "content_types" => Enum.sort(Schemas.Attachment.mockup_types()),
        "request" => mockup_placeholders(mockups_request),
        "card_mockups" => mockup_placeholders(mockups_response["data"]["mockups"]),
        "append_request" => mockup_placeholders(mockups_append_request),
        "append_path" => mockups_append_path,
        "remove_path" => mockup_remove_path
      },
      "vocabulary" => %{
        # RE433 — `./relay`'s HARNESS_PLACEHOLDERS must equal Schemas.Harness.placeholders/0.
        "harness_placeholders" => Schemas.Harness.placeholders(),
        # RE436 — `./relay`'s USAGE_SOURCES / USAGE_USED_UNITS / USAGE_RESETS_UNITS mirror these.
        "usage_sources" => Schemas.HarnessUsage.sources(),
        "usage_used_units" => Schemas.HarnessUsage.used_units(),
        "usage_resets_units" => Schemas.HarnessUsage.resets_units(),
        "run_states" => %{
          "active" => stringify(Schemas.Run.active_statuses()),
          "terminal" => stringify(Schemas.Run.terminal_statuses())
        },
        "outcomes" => stringify(Schemas.NodeExecution.outcomes()),
        # RE308 — `outcomes` is what a RUNNER may report (it now includes `blocked`);
        # `agent_outcomes` is what an AGENT may declare via `./relay outcome` (NODE_OUTCOMES),
        # which is exactly the routable set. Two pins, so neither side can widen one silently.
        "agent_outcomes" => stringify(Schemas.NodeExecution.routable_outcomes()),
        "audit_severities" => stringify(Audit.severities()),
        "audit_checks" => stringify(Audit.checks()),
        "isolation" => stringify(Schemas.Flow.isolation_classes()),
        "node_types" => %{"runnable" => stringify(Schemas.Flow.Node.runnable_types())},
        # RE268 — `./relay` types "done"/"stopped"/"failed" and "error" as literals on the
        # talk wire, and a drift is silent in the worst direction: a renamed status 422s BOTH
        # the primary and the crash-path outcome POST (stranding the turn `:claimed` forever),
        # and a renamed event kind makes `normalize_event/1` degrade error lines to ordinary
        # output, undetectably. AGENTS.md: anything mirrored into ./relay is pinned here.
        "talk_turn_statuses" => %{
          "active" => stringify(Schemas.TalkTurn.active_statuses()),
          "reportable" => stringify(Schemas.TalkTurn.reportable_statuses())
        },
        "talk_event_kinds" => stringify(Schemas.TalkEvent.kinds()),
        # RE311 — `./relay` derives these four labels itself (`RunnerPool._holding_state`)
        # and the server SKIPS any it does not recognise, so a drift leaks an exclusive slot
        # silently rather than erroring. Pinned here like every other mirrored vocabulary.
        # Already strings on both sides (the field only ever exists on the wire), so no
        # `stringify/1`.
        "holding_states" => Schemas.Runner.holding_states(),
        # RE320 → RE436 — `./relay` mirrors this as USAGE_PAUSE_REASONS; the server stores nil
        # for any value outside it, so a drift would silently erase the pause. Windows are
        # per-harness labels now, so no window vocabulary is mirrored.
        "rate_limit_reasons" => Schemas.Runner.rate_limit_reasons(),
        # RE384 — `./relay stage lane|add|set` validate against these before calling the API.
        "stage_lanes" => stringify(Schemas.Stage.sublane_types()),
        "stage_types" => stringify(Schemas.Stage.types()),
        "stage_categories" => stringify(Schemas.Stage.categories()),
        # RE430 — the closed sets a `problem` object's `kind` and each fix's `action` draw from.
        "shape_problem_kinds" => stringify(Shape.kinds()),
        "shape_fix_actions" => stringify(Shape.fix_actions())
      },
      "stages" => %{"stage_keys" => stage_object |> Map.keys() |> Enum.sort()},
      "flows" => %{
        "trigger_keys" => flow_doc["trigger"] |> Map.keys() |> Enum.sort(),
        "derived_keys" => flow_doc["derived"] |> Map.keys() |> Enum.sort(),
        "problem_keys" => paused_problem |> Map.keys() |> Enum.sort(),
        "fix_keys" => paused_problem["fixes"] |> hd() |> Map.keys() |> Enum.sort(),
        "column_keys" => paused_problem["columns"] |> hd() |> Map.keys() |> Enum.sort()
      },
      "claim_request" => normalize(claim_body(%{"shared_clean" => 1})),
      "claim" => %{
        "shared_clean_agent" => normalize(shared_clean_agent),
        "exclusive_shell" => normalize(exclusive_shell),
        "resumed_agent" => normalize(resumed_agent)
      },
      "claim_refused" => %{
        "outdated" => normalize_refusal(outdated_refusal),
        "plan_paused" => normalize_paused_refusal(plan_paused_refusal)
      },
      "outcome" => %{
        "request" => normalize(outcome_request),
        "response" => normalize(outcome_response)
      },
      "heartbeat" => %{
        "request" => normalize(heartbeat_request),
        "response" => normalize(heartbeat_response)
      },
      "harnesses" => %{
        "path" => "/api/harnesses",
        "response_keys" => harnesses_response |> Map.keys() |> Enum.sort(),
        "harness_keys" => harnesses_response["harnesses"] |> hd() |> Map.keys() |> Enum.sort(),
        # RE436 — the usage rule the runner applies per harness.
        "usage_keys" => harnesses_response["harnesses"] |> hd() |> Map.fetch!("usage") |> Map.keys() |> Enum.sort()
      },
      "talk_claim" => %{"first_turn" => normalize(talk_job)},
      "talk_events" => %{"request" => normalize(talk_events_request), "response" => normalize(talk_events_response)},
      "talk_outcome" => %{"request" => normalize(talk_outcome_request), "response" => normalize(talk_outcome_response)},
      "scaffold" => %{
        "manifest_path" => "/api/scaffold",
        "file_path_example" => "/api/scaffold/relay",
        # RE443 — the BOARD_URL line the app bakes into a served ./relay; ./relay's
        # BOARD_URL_RE parses it back.
        "board_url_line_example" => Scaffold.board_url_line("http://board.test"),
        "manifest" => scaffold_placeholders(scaffold_manifest),
        # RE478 — the query param that picks a layout, and each layout's runner item path.
        "layout_param" => Scaffold.layout_param(),
        "layouts" => Map.new(Scaffold.layouts(), &{&1, Scaffold.runner_path(&1)}),
        "manifest_hamaca" => scaffold_placeholders(scaffold_manifest_hamaca)
      },
      "setup" => setup,
      # RE478 — owned by ./hamaca, not the app: the env prefixes it reads in precedence order, the
      # suffixes it reads and the ones it exports to every node and hook under both prefixes.
      # Pinned here so a drift on either side breaks CI.
      "env" => %{
        "prefixes" => ["HAMACA_", "RELAY_"],
        "read" => ~w(URL API_KEY STATE_DIR RUNNER_LOCK_DIR UPDATED_FROM UPDATE_ATTEMPTS NODE_OUTCOME),
        "exported" => ~w(NODE_SCRATCH NODE_OUTCOME PLAN REF BRANCH BASE WORKTREE CACHE_DIR)
      },
      # RE486 — the names a runner may run as (`Schemas.Runner.cli_names/0`, mirrored by
      # ./hamaca's CLI_NAMES) and the first RUNNER_VERSION that shipped as ./hamaca, below which a
      # runner reporting no `cli` reads as pre-rename (`Hamaca.Runs.pre_rename_runner?/1`).
      "runner" => %{
        "cli_names" => Schemas.Runner.cli_names(),
        "first_hamaca_version" => Runs.first_hamaca_runner_version()
      },
      "tasks" => %{
        "create_request" => tasks_create_request,
        "create_response" => task_placeholders(tasks_create_response),
        "list_response" => task_placeholders(tasks_list_response),
        "show_response" => task_placeholders(tasks_show_response),
        "update_request" => tasks_update_request,
        "update_response" => task_placeholders(tasks_update_response),
        "delete_response" => task_placeholders(tasks_delete_response)
      }
    }

    assert document["note_images"]["image"] == ["download_path", "filename", "url"]
    assert "images" in document["note_images"]["comment_entry"]
    assert "origin" in document["note_images"]["comment_entry"]
    assert note_entry["origin"] == %{"kind" => "answer", "question" => 2}
    assert document["note_images"]["origin_kinds"] == ["answer", "rejection"]
    assert document["version"] == 15

    # RE478 scenario 14: the default stays today's five legacy items; ?layout=hamaca is nine.
    assert document["scaffold"]["layout_param"] == "layout"
    assert document["scaffold"]["layouts"] == %{"hamaca" => "hamaca", "legacy" => "relay"}

    assert Enum.map(document["scaffold"]["manifest"]["items"], & &1["path"]) == [
             ".claude/skills/relay-doctor/SKILL.md",
             ".claude/skills/relay-onboard/SKILL.md",
             ".claude/skills/relay-update/SKILL.md",
             "relay",
             "relay.md"
           ]

    assert Enum.map(document["scaffold"]["manifest_hamaca"]["items"], & &1["path"]) == [
             ".claude/skills/hamaca-doctor/SKILL.md",
             ".claude/skills/hamaca-onboard/SKILL.md",
             ".claude/skills/hamaca-update/SKILL.md",
             ".claude/skills/relay-doctor/SKILL.md",
             ".claude/skills/relay-onboard/SKILL.md",
             ".claude/skills/relay-update/SKILL.md",
             "hamaca",
             "hamaca.md",
             "relay"
           ]

    assert document["scaffold"]["manifest_hamaca"]["version"] == "<scaffold-version>"

    for item <- document["scaffold"]["manifest_hamaca"]["items"] do
      assert item["sha256"] == "<sha256>"
      assert item["bytes"] == "<bytes>"
    end

    assert document["usage_rule_cases"] == Hamaca.UsageRuleCases.cases()
    assert "usage" in document["harnesses"]["harness_keys"]

    assert document["harnesses"]["usage_keys"] ==
             ["command", "interval_min", "match", "pause_now", "recheck", "resets_unit", "source", "used_unit", "windows"]

    assert document["vocabulary"]["usage_sources"] == ["output", "command", "none"]

    assert document["flows"] == %{
             "trigger_keys" => ["stage"],
             "derived_keys" => ["lands_on", "pulls_from"],
             "problem_keys" => ["columns", "fixes", "flow_key", "kind", "what", "why"],
             "fix_keys" => ["action", "label"],
             "column_keys" => ["mark", "name", "stage_id", "type"]
           }

    assert document["vocabulary"]["shape_problem_kinds"] == [
             "no_upstream",
             "upstream_review",
             "upstream_working",
             "no_downstream"
           ]

    assert document["vocabulary"]["shape_fix_actions"] == ["enable_lane", "insert_queue_stage", "add_stage_after"]
    assert "problem" in document["stages"]["stage_keys"]

    # RE433 — every node claim carries the harness it resolved to; a shell node carries none.
    for {case_name, claim} <- document["claim"] do
      assert Map.has_key?(claim, "harness") and Map.has_key?(claim, "model") and Map.has_key?(claim, "effort"),
             case_name
    end

    assert document["claim"]["shared_clean_agent"]["harness"]["key"] == "claude-code"
    assert document["claim"]["exclusive_shell"]["harness"] == nil
    assert document["heartbeat"]["response"]["harnesses_digest"] == "<harnesses-digest>"
    assert document["harnesses"]["response_keys"] == ["digest", "harnesses"]

    # RE436 — the per-harness usage wire replaces the runner-wide `rate_limit`.
    refute Map.has_key?(document["heartbeat"]["request"], "rate_limit")
    assert hd(document["heartbeat"]["request"]["harnesses"])["usage"]["paused"]["reason"] == "limit"
    assert document["claim_request"]["harnesses"] == ["claude-code"]
    refute Map.has_key?(document["vocabulary"], "rate_limit_windows")

    # RE445 — the setup wire ./relay setup builds against.
    assert document["setup"]["report_statuses"] == ["waiting", "done", "failed", "skipped"]
    assert document["setup"]["not_current_keys"] == ["code", "current", "message"]
    assert document["setup"]["report_path_example"] == "/api/setup/steps/5.1"

    assert Enum.all?(
             ~w(current current_sub_id first_flow_stage interview steps),
             &(&1 in document["setup"]["status_keys"])
           )

    assert Enum.all?(~w(children data evidence error status), &(&1 in document["setup"]["step_keys"]))

    # RE457 — the runner.json defaults and the relay.md pointer line ./relay asserts against.
    assert document["setup"]["llm_keys"] == ~w(cli harness label pointer_file skill_dir skill_path)
    assert document["setup"]["pointer_line"] == "Working Hamaca cards from this repo: see [hamaca.md](hamaca.md)."

    # RE478 — the runner names its CLI on every claim and heartbeat (RE486 stores it on
    # `runners.cli`), and the env twins + CLI names ./hamaca defines are pinned here.
    assert document["claim_request"]["runner"]["cli"] == "hamaca"
    assert document["heartbeat"]["request"]["runner"]["cli"] == "hamaca"
    assert document["env"]["prefixes"] == ["HAMACA_", "RELAY_"]
    assert "API_KEY" in document["env"]["read"] and "NODE_SCRATCH" in document["env"]["exported"]
    assert document["runner"]["cli_names"] == ["hamaca", "relay"]
    assert document["runner"]["first_hamaca_version"] == 94
    assert document["runner"] == %{"cli_names" => ["hamaca", "relay"], "first_hamaca_version" => 94}

    assert document["setup"]["runner_config_defaults"] == %{
             "pointer_file" => "CLAUDE.md",
             "skill_dir" => ".claude/skills"
           }

    assert_matches_fixture!(document)
  end

  # One place builds the `runner` dict for both claim and heartbeat, mirroring ./relay's
  # runner_ident (RLY-184). The version tracks `shared_talk_min_version/0` (RE366) so the fixture
  # always depicts a CURRENT runner — a literal would start 409ing the moment the minimum moves.
  # That makes it talk-capable (`Hamaca.Runs.talk_capable?/1`, at `min_runner_version/0`) AND
  # able to take the `shared_clean` talk turn it claims, which
  # `Hamaca.Runs.shared_talk_capable?/1` hides from a runner below the shared-talk floor.
  #
  # `cli` (RE478) is the name the runner runs as — `"hamaca"` or `"relay"`; the server stores it
  # on `runners.cli` through `Schemas.Runner.normalize_cli/1` (RE486).
  defp runner_ident do
    %{
      "name" => "fixture",
      "host" => "fixture-host",
      "interval" => 30,
      "version" => Runs.shared_talk_min_version(),
      "cli" => "hamaca"
    }
  end

  # `running` (RE268) is what lets a no-job claim reply carry `revoked` — the fast Stop path.
  # `held` (RE311) is what lets a job for a card this runner already holds the worktree for be
  # offered at zero free capacity.
  # `harnesses` (RE436) is the installed harnesses minus the ones paused at a usage limit; the
  # server ignores it until it filters claims by it.
  defp claim_body(capacity),
    do: %{
      "runner" => runner_ident(),
      "capacity" => capacity,
      "running" => [],
      "held" => [],
      "harnesses" => ["claude-code"]
    }

  defp stringify(atoms), do: Enum.map(atoms, &Atom.to_string/1)

  defp agent_node do
    %{key: "work", type: :agent, run: "/write-plan {ref}", agent: "plan-implementer"}
  end

  defp shell_node do
    %{key: "work", type: :shell, run: "mix precommit"}
  end

  # One board per flow. A stage holds at most one flow (RE429) and the board seeds its own
  # (disabled) default flows, so the seeded `spec` flow is removed to free Spec — whose pickup
  # is Next up — for the contract flow. A second board is cheaper and more deterministic than
  # hunting for a free stage on the first.
  defp board_with_flow(user, name, key, isolation, node) do
    {:ok, board} = Hamaca.Boards.create_board(user, %{name: name, key: key})
    {:ok, %{token: token}} = Hamaca.ApiKeys.create_key(board, user)
    :ok = Runs.subscribe(board.id)

    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    {:ok, _} = Hamaca.Flows.delete_flow(Hamaca.Flows.get_flow!(board, "spec"))

    {:ok, flow} =
      Hamaca.Flows.create_flow(board, %{
        key: "contract",
        isolation: isolation,
        stage_id: spec.id,
        nodes: [node],
        edges: [
          %{from: "start", to: "work"},
          %{from: "work", to: "done", on: :succeeded},
          %{from: "work", to: "done", on: :failed},
          %{from: "work", to: "done", on: :partial}
        ]
      })

    {:ok, flow} = Hamaca.Flows.enable_flow(flow)

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    %{board: board, flow: flow, conn: conn, next_up: next_up}
  end

  # A Bare minimum board on setup sub-step 5.1 with its board key: the GET, a 200 report carrying
  # every request key, a 409 out-of-order report, and a 404 from `no_checklist_conn`'s board.
  defp setup_capture(user, no_checklist_conn) do
    {:ok, board} =
      Hamaca.Boards.create_board(user, %{name: "Contract setup", slug: "contract-setup", template: "bare-minimum"})

    {:ok, %{token: token}} = Hamaca.Setup.choose_llm(board, user, "claude-code")
    for step <- ~w(3 4), do: {:ok, _} = Hamaca.Setup.advance(board, step, :done, %{})

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    status = conn |> get(~p"/api/setup") |> json_response(200) |> Map.fetch!("data")
    current = status["current"]

    report_request = %{
      "status" => "failed",
      "evidence" => "422 · attempt 3/3",
      "error" => "422",
      "data" => %{"attempts" => 3}
    }

    conn |> post(~p"/api/setup/steps/#{current}", Jason.encode!(report_request)) |> json_response(200)

    not_current =
      conn
      |> post(~p"/api/setup/steps/#{List.last(Hamaca.Setup.steps()).id}", Jason.encode!(%{"status" => "done"}))
      |> json_response(409)
      |> Map.fetch!("error")

    no_checklist = no_checklist_conn |> get(~p"/api/setup") |> json_response(404) |> Map.fetch!("error")
    [step | _] = status["steps"]

    %{
      "status_path" => "/api/setup",
      "report_path_example" => "/api/setup/steps/#{current}",
      "status_keys" => status |> Map.keys() |> Enum.sort(),
      "step_keys" => step |> Map.keys() |> Enum.sort(),
      "llm_keys" => status["llm"] |> Map.keys() |> Enum.sort(),
      "interview_keys" => status["interview"] |> hd() |> Map.keys() |> Enum.sort(),
      "report_request_keys" => report_request |> Map.keys() |> Enum.sort(),
      "report_statuses" => Enum.map(Hamaca.Setup.advance_statuses(), &Atom.to_string/1),
      "not_current_keys" => not_current |> Map.keys() |> Enum.sort(),
      "no_checklist_code" => no_checklist["code"],
      "not_current_code" => not_current["code"],
      # RE457 — what ./relay writes into a runner.json it creates, and the relay.md pointer line.
      "pointer_line" => Hamaca.Setup.pointer_line(),
      "runner_config_defaults" =>
        Hamaca.Agents.default_harness_key()
        |> Hamaca.Setup.onboarding_llm()
        |> Map.take([:skill_dir, :pointer_file])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    }
  end

  defp claim_one(ctx, capacity) do
    {:ok, card} = Hamaca.Cards.create_card(ctx.next_up, %{title: "Contract card"})
    {:ok, run} = Runs.start_run(card, ctx.flow)
    {run, claim(ctx, capacity)}
  end

  defp claim(ctx, capacity) do
    ctx.conn |> post(~p"/api/node-jobs/claim", Jason.encode!(claim_body(capacity))) |> json_response(200)
  end

  # UUIDs would make the file churn on every run. Everything else — including
  # derived-but-deterministic values like `branch` — is written literally.
  @placeholders %{
    "id" => "<node-job-id>",
    "run_id" => "<run-id>",
    "resume_session" => "<session-id>",
    "session_id" => "<session-id>",
    "turn_id" => "<talk-turn-id>",
    # RE185: the VALUE moves on every deploy that changes `./relay`, but the contract is the
    # key and its presence — a literal would make this fixture churn (and fail) every time the
    # served scaffold's `RUNNER_VERSION` moves, which is not a transport change.
    "latest_runner_version" => "<latest-runner-version>",
    # RE433: the digest moves whenever a seeded harness definition does; the contract is the key.
    "harnesses_digest" => "<harnesses-digest>"
  }

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      case {Map.fetch(@placeholders, k), v} do
        {{:ok, _token}, nil} -> {k, nil}
        {{:ok, token}, _value} -> {k, token}
        {:error, _value} -> {k, normalize(v)}
      end
    end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  # The manifest's VALUES move whenever any served file changes; the contract is the key set
  # and the item paths. Placeholdered here rather than through @placeholders because `version`
  # is also a key on the runner dict, where the real integer IS the contract.
  # The refusal's numbers move whenever the floor does, and its message is prose; the contract is
  # the code and the key set.
  defp normalize_refusal(%{"error" => error}) do
    %{
      "error" =>
        Map.merge(error, %{"required" => "<required-version>", "running" => "<running-version>", "message" => "<message>"})
    }
  end

  # The paused refusal's message is prose; the contract is the code and the key set.
  defp normalize_paused_refusal(%{"error" => error}), do: %{"error" => Map.put(error, "message", "<message>")}

  # Task ids are serial and would churn the fixture; the contract is the key set and the
  # values that are deterministic (titles, bodies, done, position).
  defp task_placeholders(map) when is_map(map) do
    Map.new(map, fn
      {"id", _id} -> {"id", "<task-id>"}
      {key, value} -> {key, task_placeholders(value)}
    end)
  end

  defp task_placeholders(list) when is_list(list), do: Enum.map(list, &task_placeholders/1)
  defp task_placeholders(other), do: other

  # Attachment ids are random UUIDs and would churn the fixture; the contract is the key set,
  # the /attachments/ shape and the caption.
  defp mockup_placeholders(map) when is_map(map) do
    Map.new(map, fn
      {"url", url} when is_binary(url) -> {"url", Schemas.Attachment.path("<attachment-id>")}
      {key, value} -> {key, mockup_placeholders(value)}
    end)
  end

  defp mockup_placeholders(list) when is_list(list), do: Enum.map(list, &mockup_placeholders/1)
  defp mockup_placeholders(other), do: other

  defp scaffold_placeholders(manifest) do
    %{
      "version" => "<scaffold-version>",
      "items" =>
        Enum.map(manifest["items"], fn item ->
          # RE443: the runner item also carries `unbaked_sha256`; keep the key, mask the value.
          Map.new(item, fn
            {"path", path} -> {"path", path}
            {"bytes", _} -> {"bytes", "<bytes>"}
            {key, _} -> {key, "<sha256>"}
          end)
        end)
    }
  end

  defp assert_matches_fixture!(document) do
    if System.get_env("RELAY_WRITE_CONTRACT_FIXTURE") == "1" do
      File.write!(@fixture_path, encode(document))

      flunk("""
      Rewrote #{@fixture_path} from the live routes. Review the diff, then re-run WITHOUT
      RELAY_WRITE_CONTRACT_FIXTURE=1. Failing on purpose so a regenerated fixture is never
      green in the same run that generated it.
      """)
    end

    committed = @fixture_path |> File.read!() |> Jason.decode!()

    assert committed == document, """
    #{@fixture_path} no longer matches what /api/node-jobs/* actually sends.

    bin/test_relay.py builds every job dict from that file, so this is the seam guard, not a
    snapshot nit. If the change is intended, regenerate and review the diff:

        RELAY_WRITE_CONTRACT_FIXTURE=1 mix test test/hamaca_web/controllers/api/runner_contract_test.exs
    """
  end

  # Stable key order so the committed file is diffable.
  defp encode(document), do: document |> ordered() |> Jason.encode!() |> Jason.Formatter.pretty_print()

  defp ordered(map) when is_map(map) do
    values = map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> {k, ordered(v)} end)
    %Jason.OrderedObject{values: values}
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(other), do: other
end
