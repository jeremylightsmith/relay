defmodule RelayWeb.PageHTML.Landing do
  @moduledoc """
  Landing-only function components for the signed-out home page (`/`, RE476): the hero
  visual slot, the three "Review by looking" replicas (board, browser, phone), the silent
  stall's terminals panel and the How it works stage strip.

  The replicas are static, inert copies of the real components (`stage_column/1` +
  `board_card/1`, `card_mockup_viewer/1` + `card_review_panel/1`, `mobile_nav_bar/1` + the
  native `CardReviewBar`). They are **transcribed, not called**: the real components bring
  fixed overlays, `phx-*` bindings, iframes, drag hooks and fixed ids. So inside a replica
  there are no ids, no `<button>`/`<form>`/`<iframe>` and no bindings — buttons are
  `<span class="btn …">`. Only the replica roots carry an id, so tests can select them.

  These are landing-only, so they have no Storybook stories.
  """
  use RelayWeb, :html

  alias Phoenix.LiveView.Rendered

  # The one place the landing's recipe photo path lives (CC BY 2.0, credited in the footer).
  defp lemon_photo, do: ~p"/images/landing/lemon-spaghetti.jpg"

  defp lemon_background,
    do: "background-image:url(#{lemon_photo()});background-size:cover;background-position:center 40%;"

  @doc """
  The hero's picture slot: a placeholder hammock illustration plus the notification that
  just lit up the phone. The illustration's colors live in `il_style/1` so swapping in a
  raster image later touches only this component and `priv/static/images/`.
  """
  @spec landing_hero_visual(map()) :: Rendered.t()
  def landing_hero_visual(assigns) do
    ~H"""
    <div id="landing-hero-visual" class="relative mx-auto w-full max-w-[560px]">
      <svg
        viewBox="0 0 540 430"
        class="w-full"
        role="img"
        aria-label="A person relaxing in a hammock between two palm trees, holding a drink and a phone that has just lit up"
      >
        <circle style={il_style(:sun)} cx="300" cy="96" r="64" />
        <ellipse style={il_style(:ground)} cx="270" cy="404" rx="250" ry="18" />
        <path
          style={il_style(:trunk)}
          d="M70 400 C58 310 54 210 86 112"
          stroke-width="16"
          fill="none"
          stroke-linecap="round"
        />
        <path
          style={il_style(:trunk)}
          d="M470 400 C482 310 486 210 454 112"
          stroke-width="16"
          fill="none"
          stroke-linecap="round"
        />
        <g style={il_style(:leaf)}>
          <path d="M86 112 C60 80 30 82 8 102 C40 92 62 100 86 112Z" />
          <path d="M86 112 C80 70 100 44 132 40 C108 60 96 84 86 112Z" />
          <path d="M86 112 C114 86 150 88 170 112 C140 102 112 104 86 112Z" />
          <path d="M86 112 C56 104 36 124 34 152 C50 128 66 118 86 112Z" />
          <path d="M86 112 C70 82 44 62 18 64 C46 76 66 90 86 112Z" />
          <path d="M454 112 C480 80 510 82 532 102 C500 92 478 100 454 112Z" />
          <path d="M454 112 C460 70 440 44 408 40 C432 60 444 84 454 112Z" />
          <path d="M454 112 C426 86 390 88 370 112 C400 102 428 104 454 112Z" />
          <path d="M454 112 C484 104 504 124 506 152 C490 128 474 118 454 112Z" />
          <path d="M454 112 C470 82 496 62 522 64 C494 76 474 90 454 112Z" />
        </g>
        <path
          style={il_style(:rope)}
          d="M80 196 L140 236 M80 196 L136 246 M80 196 L146 228 M462 196 L402 236 M462 196 L406 246 M462 196 L396 228"
          stroke-width="2.5"
          stroke-linecap="round"
          fill="none"
        />
        <path
          style={il_style(:pants)}
          d="M300 262 C336 254 366 236 404 214"
          stroke-width="20"
          fill="none"
          stroke-linecap="round"
        />
        <path
          style={il_style(:pants)}
          d="M300 270 C340 270 372 254 412 236"
          stroke-width="20"
          fill="none"
          stroke-linecap="round"
        />
        <ellipse
          style={il_style(:skin)}
          cx="414"
          cy="208"
          rx="9"
          ry="13"
          transform="rotate(-30 414 208)"
        />
        <ellipse
          style={il_style(:skin)}
          cx="422"
          cy="230"
          rx="9"
          ry="13"
          transform="rotate(-50 422 230)"
        />
        <path
          style={il_style(:shirt)}
          d="M176 230 C200 210 262 222 306 250 L298 278 C252 270 202 266 168 256 Z"
        />
        <circle style={il_style(:skin)} cx="168" cy="206" r="21" />
        <path
          style={il_style(:hair)}
          d="M148 202 C146 182 166 172 184 180 C176 184 170 190 168 198 C160 196 154 198 148 202Z"
        />
        <path style={il_style(:hair)} d="M174 200 L190 196 L190 204 L176 207 Z" />
        <path
          style={il_style(:smile)}
          d="M178 216 C182 219 186 218 189 215"
          stroke-width="2"
          fill="none"
          stroke-linecap="round"
        />
        <path
          style={il_style(:skin_stroke)}
          d="M198 232 C192 206 200 186 214 170"
          stroke-width="12"
          fill="none"
          stroke-linecap="round"
        />
        <path style={il_style(:bed)} d="M136 236 Q270 290 402 236 Q270 392 136 236Z" />
        <path style={il_style(:bed_stripe)} d="M146 246 Q270 352 392 246 Q270 368 146 246Z" />
        <path
          style={il_style(:skin_stroke)}
          d="M236 262 C244 286 248 300 252 318"
          stroke-width="12"
          fill="none"
          stroke-linecap="round"
        />
        <path style={il_style(:glass)} d="M240 304 L270 304 L266 350 L244 350 Z" />
        <path style={il_style(:drink)} d="M242 316 L268 316 L266 348 L244 348 Z" />
        <path
          style={il_style(:straw)}
          d="M262 312 L276 282"
          stroke-width="3"
          stroke-linecap="round"
          fill="none"
        />
        <circle style={il_style(:lemon)} cx="241" cy="306" r="8" />
        <circle style={il_style(:glow)} cx="222" cy="150" r="34" />
        <g transform="rotate(-14 222 150)">
          <rect style={il_style(:phone)} x="206" y="122" width="32" height="56" rx="6" />
          <rect style={il_style(:screen)} x="209" y="127" width="26" height="46" rx="3" />
          <circle style={il_style(:andon)} cx="222" cy="136" r="3.5" />
          <rect style={il_style(:screen_line)} x="212" y="146" width="20" height="10" rx="1.5" />
          <rect style={il_style(:screen_ok)} x="212" y="160" width="20" height="5" rx="1.5" />
        </g>
      </svg>
      <div class="absolute left-1/2 top-0 w-[230px] -translate-x-[78%] rounded-2xl border border-base-300 bg-base-100 p-2.5 text-left shadow-xl sm:w-[285px] md:-left-6 md:top-2 md:translate-x-0">
        <div class="mb-1.5 flex items-center gap-1.5">
          <.hamaca_mark class="h-[12px]" />
          <span class="text-[11px] font-semibold">Hamaca</span>
          <span class="flex-1"></span>
          <span class="size-1.5 rounded-full bg-warning" style={il_style(:andon_glow)}></span>
          <span class="font-mono text-[10px] text-base-content/50">now</span>
        </div>
        <div class="flex gap-2.5">
          <img
            src={lemon_photo()}
            alt="A bowl of lemon spaghetti"
            class="block size-12 shrink-0 rounded-md border border-base-300 object-cover"
          />
          <div class="min-w-0">
            <div class="text-[12px] font-semibold leading-snug">
              Recipe page: 2 mockups to look at
            </div>
            <div class="mt-0.5 text-[11px] leading-snug text-base-content/60">Tap to see them.</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The placeholder illustration's palette: every color is a mix of daisyUI tokens, so it
  # flips with `data-theme`. Kept here (not in app.css) so the slot is self-contained.
  defp il_style(:sun), do: "fill:color-mix(in oklab, var(--color-warning) 22%, transparent)"
  defp il_style(:ground), do: "fill:var(--color-base-200)"
  defp il_style(:trunk), do: "stroke:color-mix(in oklab, var(--color-warning) 40%, var(--color-neutral))"
  defp il_style(:leaf), do: "fill:color-mix(in oklab, var(--color-success) 75%, var(--color-base-100))"
  defp il_style(:rope), do: "stroke:color-mix(in oklab, var(--color-base-content) 45%, var(--color-base-100))"
  defp il_style(:bed), do: "fill:var(--color-primary)"
  defp il_style(:bed_stripe), do: "fill:var(--color-secondary)"
  defp il_style(:skin), do: "fill:#{skin_tone()}"
  defp il_style(:skin_stroke), do: "stroke:#{skin_tone()}"
  defp il_style(:hair), do: "fill:var(--color-neutral)"
  defp il_style(:smile), do: "stroke:var(--color-neutral)"
  defp il_style(:shirt), do: "fill:color-mix(in oklab, var(--color-info) 55%, var(--color-base-100))"
  defp il_style(:pants), do: "stroke:color-mix(in oklab, var(--color-base-content) 60%, var(--color-base-100))"

  defp il_style(:glass),
    do:
      "fill:color-mix(in oklab, var(--color-info) 18%, var(--color-base-100));stroke:color-mix(in oklab, var(--color-base-content) 35%, transparent);stroke-width:1.5"

  defp il_style(:drink), do: "fill:color-mix(in oklab, var(--color-warning) 70%, var(--color-base-100))"
  defp il_style(:straw), do: "stroke:var(--color-error)"

  defp il_style(:lemon),
    do:
      "fill:color-mix(in oklab, var(--color-warning) 55%, var(--color-success) 20%);stroke:var(--color-base-100);stroke-width:2"

  defp il_style(:glow), do: "fill:color-mix(in oklab, var(--color-warning) 30%, transparent)"
  defp il_style(:phone), do: "fill:var(--color-neutral)"
  defp il_style(:screen), do: "fill:var(--color-base-100)"
  defp il_style(:andon), do: "fill:var(--color-warning)"
  defp il_style(:screen_line), do: "fill:color-mix(in oklab, var(--color-base-content) 18%, var(--color-base-100))"
  defp il_style(:screen_ok), do: "fill:var(--color-success)"

  defp il_style(:andon_glow), do: andon_glow_style()

  @doc """
  The andon light's glow (an inline `box-shadow` built from the warning token), shared by
  the hero notification and the guide's JIDOKA · ANDON tile.
  """
  @spec andon_glow_style() :: String.t()
  def andon_glow_style,
    do:
      "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-warning) 25%, transparent), 0 0 18px color-mix(in oklab, var(--color-warning) 70%, transparent)"

  defp skin_tone, do: "color-mix(in oklab, var(--color-warning) 40%, var(--color-base-content) 22%)"

  @doc """
  The board replica: Backlog · Design (In progress | Review) · Code · Review · Done, with
  the two cards waiting on you lit. Below `lg` only Design and Review show.
  """
  @spec landing_board(map()) :: Rendered.t()
  def landing_board(assigns) do
    ~H"""
    <div
      id="landing-board"
      class="rounded-[18px] border border-base-300 bg-base-200 p-3 shadow-xl sm:p-4"
    >
      <div class="grid grid-cols-[2fr_1fr] items-start gap-2.5 lg:grid-cols-[1fr_1.6fr_1fr_1fr_0.8fr]">
        <div class="hidden overflow-hidden rounded-[14px] border border-base-300 bg-base-100 lg:block">
          <.replica_column_header type={:queue} name="Backlog" count={2} />
          <div class="flex flex-col gap-2 p-2.5">
            <.replica_card title="Trail log: offline maps" ref="RE163" />
            <.replica_card title="Scale servings" ref="RE161" />
          </div>
        </div>
        <div class="overflow-hidden rounded-[14px] border border-base-300 bg-base-100">
          <.replica_column_header type={:planning} name="Design" count={2} size={9} />
          <div class="grid grid-cols-2">
            <div class="flex flex-col gap-2 p-2.5">
              <span class="font-mono text-[10.5px] font-semibold text-base-content/55">
                In progress
              </span>
              <.replica_card title="Import from Strava" ref="RE158" state={:working} />
            </div>
            <div class="flex flex-col gap-2 bg-warning/5 p-2.5">
              <span class="font-mono text-[10.5px] font-semibold text-warning">Review</span>
              <.replica_card title="Redesign the recipe page" ref="RE142" state={:review} />
            </div>
          </div>
        </div>
        <div class="hidden overflow-hidden rounded-[14px] border border-base-300 bg-base-100 lg:block">
          <.replica_column_header type={:work} name="Code" count={2} />
          <div class="flex flex-col gap-2 p-2.5">
            <.replica_card title="Invoice PDFs" ref="RE150" state={:working} />
            <.replica_card title="Keyboard shortcuts" ref="RE153" state={:working} />
          </div>
        </div>
        <div class="overflow-hidden rounded-[14px] border border-base-300 bg-base-100">
          <.replica_column_header type={:review} name="Review" count={1} />
          <div class="flex flex-col gap-2 p-2.5">
            <.replica_card title="Dark mode for settings" ref="RE157" state={:review} />
          </div>
        </div>
        <div class="hidden overflow-hidden rounded-[14px] border border-base-300 bg-base-100 lg:block">
          <.replica_column_header type={:done} name="Done" count={1} />
          <div class="flex flex-col gap-2 p-2.5">
            <.replica_card title="Share a list" ref="RE139" state={:done} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :name, :string, required: true
  attr :count, :integer, required: true
  attr :size, :integer, default: 11

  defp replica_column_header(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-b border-base-300 px-3 py-2.5">
      <.stage_type_icon type={@type} size={@size} />
      <span class="text-[13px] font-semibold">{@name}</span>
      <span class="font-mono text-[10.5px] text-base-content/45">{@count}</span>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :ref, :string, required: true
  attr :state, :atom, values: [:idle, :working, :review, :done], default: :idle

  defp replica_card(assigns) do
    ~H"""
    <div class={[
      "flex flex-col gap-2 rounded-[9px] border border-base-300 border-l-[3px] bg-base-100 p-2.5",
      replica_card_accent(@state)
    ]}>
      <span class={[
        "text-[12.5px] font-medium leading-snug",
        @state == :done && "text-base-content/55"
      ]}>
        {@title}
      </span>
      <%= case @state do %>
        <% :working -> %>
          <span class="flex flex-wrap gap-x-1.5 font-mono text-[10.5px]">
            <span class="text-base-content/55">{@ref}</span>
            <span class="text-secondary">working</span>
          </span>
        <% :review -> %>
          <span class="flex flex-wrap items-center gap-1.5">
            <span class="font-mono text-[10.5px] text-base-content/55">{@ref}</span>
            <span class="badge badge-sm badge-warning text-[10px] font-medium">review</span>
          </span>
        <% _idle_or_done -> %>
          <span class="font-mono text-[10.5px] text-base-content/55">{@ref}</span>
      <% end %>
    </div>
    """
  end

  defp replica_card_accent(:working), do: "border-l-secondary"

  defp replica_card_accent(:review), do: "border-l-warning ring-2 ring-warning/60 ring-offset-2 ring-offset-base-100"

  defp replica_card_accent(_idle_or_done), do: "border-l-base-300"

  @doc """
  The browser replica: the Design · Review card (RE142) open in the mockup viewer, with the
  review panel and the AI's recipe-page mockup.
  """
  @spec landing_browser(map()) :: Rendered.t()
  def landing_browser(assigns) do
    assigns = assign(assigns, :lemon_background, lemon_background())

    ~H"""
    <div
      id="landing-browser"
      class="overflow-hidden rounded-[14px] border border-base-300 bg-base-200 text-left shadow-2xl lg:col-span-3 lg:-ml-4"
    >
      <div class="flex items-center gap-1.5 border-b border-base-300 bg-base-100 px-3 py-2">
        <span class="size-2.5 rounded-full bg-base-300"></span>
        <span class="size-2.5 rounded-full bg-base-300"></span>
        <span class="size-2.5 rounded-full bg-base-300"></span>
      </div>
      <div class="flex flex-col sm:flex-row">
        <aside class="order-2 flex w-full shrink-0 flex-col border-t border-base-300 bg-base-100 sm:order-1 sm:w-[250px] sm:border-t-0">
          <div class="hidden border-b border-base-300 px-3 py-2 sm:block">
            <span class="btn btn-ghost btn-sm gap-1.5 px-2">
              <span aria-hidden="true">←</span>Back to card
            </span>
          </div>
          <div class="flex flex-col gap-1.5 border-b border-base-300 px-4 py-3">
            <div class="flex items-center gap-2">
              <span class="badge badge-sm badge-primary h-5 rounded-[4px] border-none text-[12px]">
                Design · Review
              </span>
              <span class="font-mono text-xs text-base-content/65">RE142</span>
            </div>
            <h3 class="text-base font-semibold leading-[1.3]">Redesign the recipe page</h3>
          </div>
          <div class="flex flex-1 flex-col gap-5 p-4">
            <section class="flex flex-col gap-3 rounded-[10px] border border-success/30 bg-success/5 p-3.5">
              <span class="font-mono text-[10px] font-semibold tracking-[0.05em] text-success">
                READY FOR YOUR REVIEW
              </span>
              <p class="text-[13px] leading-normal text-base-content/80">
                Hamaca AI finished this. Approve to move it forward, or send it back with a note.
              </p>
              <div class="flex gap-2">
                <span class="btn btn-success btn-sm flex-1 rounded-lg font-semibold">Approve</span>
                <span class="btn btn-sm flex-1 whitespace-nowrap rounded-lg border-base-300 bg-base-100 px-1 font-semibold">
                  Request changes
                </span>
              </div>
            </section>
            <section class="space-y-2">
              <span class="font-mono text-[10px] font-semibold uppercase tracking-[0.06em] text-base-content/60">
                Mockups
              </span>
              <div class="flex flex-wrap gap-3 p-0.5">
                <span class="relative block size-20 shrink-0 overflow-hidden rounded-md border border-base-300 bg-base-100 ring-2 ring-primary ring-offset-2 ring-offset-base-100">
                  <span class="absolute inset-x-2 top-2 h-1 rounded-full bg-base-content/20"></span>
                  <span
                    class="absolute inset-x-2 top-[14px] h-4 rounded-sm"
                    style={@lemon_background}
                  >
                  </span>
                  <span class="absolute inset-x-2 bottom-2 top-8 flex gap-1">
                    <span class="w-1/3 rounded-sm border border-base-300"></span>
                    <span class="flex-1 rounded-sm border border-base-300"></span>
                  </span>
                </span>
                <span class="relative block size-20 shrink-0 overflow-hidden rounded-md border border-base-300 bg-base-100">
                  <span class="absolute inset-x-2 top-2 h-1 rounded-full bg-base-content/20"></span>
                  <span class="absolute left-2 top-[14px] size-6 rounded-sm" style={@lemon_background}>
                  </span>
                  <span class="absolute left-10 right-2 top-[16px] h-1 rounded-full bg-base-content/25">
                  </span>
                  <span class="absolute inset-x-2 bottom-2 top-11 rounded-sm border border-base-300">
                  </span>
                </span>
              </div>
            </section>
          </div>
        </aside>
        <div class="order-1 flex min-w-0 flex-1 flex-col sm:order-2 sm:border-l sm:border-base-300">
          <div class="hidden min-h-11 items-center gap-3 border-b border-base-300 bg-base-100 px-4 py-2 sm:flex">
            <div class="flex min-w-0 flex-1 items-baseline gap-2">
              <span class="shrink-0 font-mono text-[10px] font-semibold uppercase tracking-[0.06em] text-base-content/60">
                Mockup
              </span>
              <span class="truncate text-sm font-semibold">A — photo header, two columns</span>
              <span class="shrink-0 font-mono text-xs text-base-content/55">1 of 2</span>
            </div>
          </div>
          <div class="p-3 sm:p-4">
            <div class="max-h-[320px] overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm sm:max-h-none">
              <div class="flex items-center gap-2 border-b border-base-300 px-4 py-2.5">
                <span class="size-3.5 rounded bg-base-content/80"></span>
                <span class="text-[12px] font-semibold">Forkful</span>
                <span class="flex-1"></span>
                <span class="hidden text-[11px] text-base-content/55 sm:inline">Recipes</span>
                <span class="hidden text-[11px] text-base-content/55 sm:inline">Saved</span>
                <span class="rounded-md bg-base-content px-2 py-1 text-[10.5px] font-semibold text-base-100">
                  Sign in
                </span>
              </div>
              <img
                src={lemon_photo()}
                alt="A bowl of lemon spaghetti with parmesan"
                class="block h-28 w-full object-cover sm:h-36"
              />
              <div class="px-5 pb-6 pt-5 sm:px-7">
                <div class="mb-1 text-[20px] font-semibold tracking-[-0.02em] sm:text-[22px]">
                  Weeknight lemon pasta
                </div>
                <div class="mb-4 text-[12px] text-base-content/60">25 min · Serves 4 · Easy</div>
                <div class="grid grid-cols-1 gap-4 sm:grid-cols-[2fr_3fr]">
                  <div>
                    <div class="mb-1.5 text-[12px] font-semibold">Ingredients</div>
                    <ul class="space-y-1 text-[11px] text-base-content/65">
                      <li
                        :for={
                          item <- [
                            "200g spaghetti",
                            "2 lemons, zested",
                            "3 cloves garlic",
                            "40g parmesan"
                          ]
                        }
                        class="flex items-center gap-1.5"
                      >
                        <span class="size-2.5 shrink-0 rounded-sm border border-base-300"></span>{item}
                      </li>
                    </ul>
                  </div>
                  <div>
                    <div class="mb-1.5 text-[12px] font-semibold">Method</div>
                    <ol class="space-y-1.5 text-[11px] text-base-content/65">
                      <li
                        :for={
                          {step, n} <-
                            Enum.with_index(
                              [
                                "Boil the pasta in well-salted water.",
                                "Warm garlic in olive oil; add zest and juice.",
                                "Toss with pasta, parmesan and basil."
                              ],
                              1
                            )
                        }
                        class="flex items-start gap-1.5"
                      >
                        <span class="rounded bg-base-content px-1.5 py-0.5 text-[9px] font-semibold text-base-100">
                          {n}
                        </span>
                        <span>{step}</span>
                      </li>
                    </ol>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The phone replica: the top-level Review card (RE157) in the app — the embedded card
  drawer with its screenshots, under the native Reject | Approve bar.
  """
  @spec landing_phone(map()) :: Rendered.t()
  def landing_phone(assigns) do
    ~H"""
    <div id="landing-phone" class="mx-auto w-[262px] lg:col-span-2 lg:mx-0">
      <div class="overflow-hidden rounded-[36px] border-[7px] border-neutral bg-base-100 shadow-2xl">
        <div class="flex justify-center pb-1.5 pt-2.5">
          <span class="h-[5px] w-16 rounded-full bg-neutral/80"></span>
        </div>
        <div class="relative flex h-9 items-center border-b border-base-300 px-1">
          <span class="flex items-center text-[13px] text-primary">
            <svg
              viewBox="0 0 20 20"
              class="size-4 fill-none stroke-current"
              stroke-width="2"
              aria-hidden="true"
            >
              <path d="M12.5 4.5 7 10l5.5 5.5" />
            </svg>
            Board
          </span>
          <span class="absolute inset-x-16 text-center font-mono text-[12px] font-semibold">
            RE157
          </span>
          <span class="ml-auto px-2 text-base-content/60">⋯</span>
        </div>
        <div class="flex flex-col gap-1.5 border-b border-base-300 px-3.5 py-2.5">
          <span>
            <span class="badge badge-sm badge-primary h-5 rounded-[4px] border-none text-[11px]">
              Review
            </span>
          </span>
          <div class="text-[14px] font-semibold leading-snug">Dark mode for settings</div>
        </div>
        <div class="flex flex-col gap-3 px-3.5 py-3">
          <section class="flex flex-col gap-1.5 rounded-[10px] border border-success/30 bg-success/5 p-2.5">
            <span class="font-mono text-[9.5px] font-semibold tracking-[0.05em] text-success">
              READY FOR YOUR REVIEW
            </span>
            <p class="text-[11.5px] leading-snug text-base-content/80">
              Hamaca AI finished this. Approve or reject below.
            </p>
          </section>
          <section class="flex flex-col gap-1.5">
            <span class="font-mono text-[9.5px] font-semibold uppercase tracking-[0.06em] text-secondary">
              AI Result
            </span>
            <div class="flex flex-col gap-2 rounded-[10px] border border-secondary/25 bg-secondary/5 p-2.5">
              <div class="flex items-baseline justify-between">
                <span class="font-mono text-[9.5px] font-semibold uppercase tracking-[0.06em] text-base-content/60">
                  Screenshots
                </span>
                <span class="text-[10px] text-base-content/55">2</span>
              </div>
              <div class="flex gap-2">
                <span class="block size-16 overflow-hidden rounded-md border border-base-300 bg-base-100 p-1.5">
                  <span class="mb-1.5 block h-1 w-8 rounded-full bg-base-content/40"></span>
                  <span class="mb-1 flex items-center justify-between">
                    <span class="block h-1 w-6 rounded-full bg-base-content/20"></span>
                    <span class="block h-2 w-3.5 rounded-full bg-base-content/20"></span>
                  </span>
                  <span class="mb-1 flex items-center justify-between">
                    <span class="block h-1 w-7 rounded-full bg-base-content/20"></span>
                    <span class="block h-2 w-3.5 rounded-full bg-primary"></span>
                  </span>
                  <span class="flex rounded-sm border border-base-300 text-[0]">
                    <span class="h-2 flex-1 bg-primary/70"></span>
                    <span class="h-2 flex-1"></span>
                    <span class="h-2 flex-1"></span>
                  </span>
                </span>
                <span class="block size-16 overflow-hidden rounded-md border border-base-300 bg-neutral p-1.5">
                  <span class="mb-1.5 block h-1 w-8 rounded-full bg-neutral-content/70"></span>
                  <span class="mb-1 flex items-center justify-between">
                    <span class="block h-1 w-6 rounded-full bg-neutral-content/35"></span>
                    <span class="block h-2 w-3.5 rounded-full bg-neutral-content/30"></span>
                  </span>
                  <span class="mb-1 flex items-center justify-between">
                    <span class="block h-1 w-7 rounded-full bg-neutral-content/35"></span>
                    <span class="block h-2 w-3.5 rounded-full bg-primary"></span>
                  </span>
                  <span class="flex rounded-sm border border-neutral-content/25 text-[0]">
                    <span class="h-2 flex-1"></span>
                    <span class="h-2 flex-1 bg-primary/80"></span>
                    <span class="h-2 flex-1"></span>
                  </span>
                </span>
              </div>
              <p class="text-[11.5px] leading-snug text-base-content/85">
                Settings now follows the system theme, with a Light / Dark / System switch.
              </p>
              <span class="text-[11px] font-medium text-primary">Show more</span>
            </div>
          </section>
        </div>
        <div class="flex gap-2 border-t border-base-300 bg-base-100 px-3 pb-5 pt-2.5">
          <span class="btn btn-sm flex-[1] rounded-[10px] border-base-300 bg-base-100 font-semibold">
            Reject
          </span>
          <span class="btn btn-primary btn-sm flex-[1.4] rounded-[10px] font-semibold">Approve</span>
        </div>
      </div>
    </div>
    """
  end

  # The silent stall's five terminals: {dir, last line, idle timer}. A timer is warning-amber
  # when the agent sits idle, muted when it is busy or unknown.
  @terminals [
    {"~/recipes", "✓ All 214 tests pass. Waiting for input.", {:idle, "idle 58m"}},
    {"~/trail-log", "? Should offline maps cache tiles or vectors?", {:idle, "idle 41m"}},
    {"~/invoices", "… writing src/pdf/render.ts", {:muted, "busy"}},
    {"~/blog", "✓ Ready for review: 6 files changed", {:idle, "idle 2h"}},
    {"~/dotfiles", "(scrolled off)", {:muted, "???"}}
  ]

  @doc """
  The silent stall's "5 terminals" panel: fixed-dark (`--color-neutral` in both themes),
  five agents, nothing telling you which one is waiting.
  """
  @spec landing_terminals(map()) :: Rendered.t()
  def landing_terminals(assigns) do
    assigns = assign(assigns, :terminals, @terminals)

    ~H"""
    <div
      id="landing-terminals"
      class="flex flex-col gap-2 rounded-[14px] p-4 shadow-xl"
      style="background:var(--color-neutral);"
    >
      <div class="mb-1 flex items-center gap-1.5">
        <span :for={_ <- 1..3} class="size-2.5 rounded-full bg-neutral-content/25"></span>
        <span class="ml-2 font-mono text-[11px] text-neutral-content/55">5 terminals</span>
      </div>
      <div class="grid grid-cols-[auto_1fr_auto] items-center gap-x-3 gap-y-2 font-mono text-[12px] text-neutral-content/80">
        <%= for {dir, line, {kind, timer}} <- @terminals do %>
          <span class="text-neutral-content/50">{dir}</span>
          <span class="truncate">{line}</span>
          <span class={if kind == :idle, do: "text-warning", else: "text-neutral-content/45"}>
            {timer}
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # The default line, owner by owner: people run Ideas, Spec and Review; agents the rest.
  @stages [
    {"Ideas", :human},
    {"Design", :ai},
    {"Spec", :human},
    {"Plan", :ai},
    {"Code", :ai},
    {"Review", :human},
    {"Deploy", :ai}
  ]

  @doc """
  How it works step 2's stage strip: the seven stages as chips, topped blue (Human) or
  violet (AI) by owner.
  """
  @spec landing_stage_strip(map()) :: Rendered.t()
  def landing_stage_strip(assigns) do
    assigns = assign(assigns, :stages, @stages)

    ~H"""
    <div id="landing-stage-strip" class="mt-auto flex flex-wrap gap-1.5">
      <span
        :for={{name, owner} <- @stages}
        class={[
          "rounded-md border border-base-300 border-t-[3px] bg-base-100 px-2 py-1.5 text-[11.5px] font-semibold",
          if(owner == :human, do: "border-t-primary", else: "border-t-secondary")
        ]}
      >
        {name}
      </span>
    </div>
    """
  end
end
