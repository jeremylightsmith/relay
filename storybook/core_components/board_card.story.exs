defmodule Storybook.Components.CoreComponents.BoardCard do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.board_card/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :unowned,
        attributes: %{id: "story-card-1", ref: "RLY-1", title: "Wire up Google sign-in"}
      },
      %Variation{
        id: :human_active,
        attributes: %{
          id: "story-card-2",
          ref: "RLY-2",
          title: "Draft the onboarding spec",
          tag: "spec",
          active_owner: :human,
          status: :ready,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]
        }
      },
      %Variation{
        id: :ai_working,
        attributes: %{
          id: "story-card-3",
          ref: "RLY-3",
          title: "Migrate 40 blog posts",
          active_owner: :ai,
          status: :working,
          progress: 61,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}, %{actor_type: :agent}]
        }
      },
      %Variation{
        id: :ready_parked,
        attributes: %{
          id: "story-card-7",
          ref: "RLY-7",
          title: "Parked, waiting its turn",
          status: :ready,
          stage_type: :queue
        }
      },
      %Variation{
        id: :ready_done_sublane,
        attributes: %{
          id: "story-card-8",
          ref: "RLY-8",
          title: "Finished this stage",
          status: :ready,
          stage_type: :done,
          done: false
        }
      },
      %Variation{
        id: :terminal_done,
        attributes: %{
          id: "story-card-9",
          ref: "RLY-9",
          title: "Ship the landing page",
          status: :ready,
          stage_type: :done,
          done: true,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]
        }
      },
      %Variation{
        id: :in_review,
        attributes: %{id: "story-card-10", ref: "RLY-10", title: "Ready for your review", status: :in_review}
      },
      %Variation{
        id: :needs_input,
        attributes: %{
          id: "story-card-11",
          ref: "RLY-11",
          title: "Pick the target locale list",
          status: :needs_input,
          question: "Should we ship en-US and de-DE first, or all five at once?",
          active_owner: :ai,
          owners: [%{actor_type: :agent}]
        }
      },
      %Variation{
        id: :ai_live,
        attributes: %{
          id: "story-card-live",
          ref: "RLY-10",
          title: "Migrate 40 blog posts",
          active_owner: :ai,
          status: :working,
          progress: 62,
          health: :live,
          log_text: "uploaded 24/40 posts",
          log_at: DateTime.utc_now(),
          owners: [%{actor_type: :agent}]
        }
      },
      %Variation{
        id: :ai_stale,
        attributes: %{
          id: "story-card-stale",
          ref: "RLY-11",
          title: "Deploy the search reindex job",
          active_owner: :ai,
          status: :working,
          health: :stale,
          log_text: "reindexing 12k documents",
          log_at: DateTime.add(DateTime.utc_now(), -8 * 60, :second),
          owners: [%{actor_type: :agent}]
        }
      },
      %Variation{
        id: :ai_stopped,
        attributes: %{
          id: "story-card-stopped",
          ref: "RLY-12",
          title: "Generate the API client",
          active_owner: :ai,
          status: :working,
          health: :stopped,
          log_text: "agent stopped",
          log_at: DateTime.add(DateTime.utc_now(), -2 * 60, :second),
          owners: [%{actor_type: :agent}]
        }
      },
      %Variation{
        id: :failed,
        attributes: %{
          id: "story-card-failed",
          ref: "RLY-20",
          title: "Generate the API client",
          active_owner: :ai,
          status: :failed,
          health: :stopped,
          log_text: "npm install failed: ETARGET no matching version",
          log_at: DateTime.add(DateTime.utc_now(), -2 * 60, :second),
          owners: [%{actor_type: :agent}]
        }
      },
      %Variation{
        id: :run_running,
        attributes: %{
          id: "story-card-run-running",
          ref: "RLY-13",
          title: "CSV export of the board",
          status: :working,
          active_owner: :ai,
          owners: [%{actor_type: :agent}],
          run:
            {:run,
             %{
               status: :running,
               node_index: 2,
               node_count: 4,
               current_node: "implement",
               flow_key: "code",
               flow_version: 3,
               attempts: 2
             }}
        }
      },
      %Variation{
        id: :run_parked,
        attributes: %{
          id: "story-card-run-parked",
          ref: "RLY-14",
          title: "Pick the target locale list",
          status: :needs_input,
          question: "Full text?",
          active_owner: :ai,
          owners: [%{actor_type: :agent}],
          run: {:run, %{status: :parked, current_node: "brainstorm", flow_key: "spec", flow_version: 2, attempts: 1}}
        }
      },
      %Variation{
        id: :run_failed,
        attributes: %{
          id: "story-card-run-failed",
          ref: "RLY-15",
          title: "Bulk move cards between stages",
          status: :working,
          active_owner: :ai,
          owners: [%{actor_type: :agent}],
          run:
            {:run,
             %{
               status: :failed,
               current_node: nil,
               last_node: "quality_review",
               flow_key: "code",
               flow_version: 3,
               attempts: 3
             }}
        }
      },
      %Variation{
        id: :run_queued,
        attributes: %{
          id: "story-card-run-queued",
          ref: "RLY-16",
          title: "Bulk move cards between stages",
          status: :ready,
          run: {:queued, %{key: "code"}}
        }
      },
      %Variation{
        id: :run_done,
        attributes: %{
          id: "story-card-run-done",
          ref: "RLY-17",
          title: "Ship the landing page",
          status: :ready,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}],
          run:
            {:run,
             %{status: :done, duration_s: 581, cost: Decimal.new("0.38"), flow_key: "code", flow_version: 3, attempts: 4}}
        }
      },
      %Variation{
        id: :run_cancelled,
        attributes: %{
          id: "story-card-run-cancelled",
          ref: "RLY-18",
          title: "Generate the API client",
          status: :working,
          active_owner: :ai,
          owners: [%{actor_type: :agent}],
          run:
            {:run,
             %{
               status: :cancelled,
               current_node: nil,
               last_node: "implement",
               flow_key: "code",
               flow_version: 3,
               attempts: 1
             }}
        }
      },
      %Variation{
        id: :run_review,
        attributes: %{
          id: "story-card-run-review",
          ref: "RLY-19",
          title: "Card drawer keyboard shortcuts",
          status: :in_review,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}],
          run: {:run, %{status: :done, duration_s: 581, cost: nil, flow_key: "code", flow_version: 3, attempts: 4}}
        }
      }
    ]
  end
end
