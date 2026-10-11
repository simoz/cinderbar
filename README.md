# Ember

> **Ember is a macOS port of [Burn Bar](https://github.com/nixfred/burnbar),
> the Omarchy bar plugin by [nixfred](https://github.com/nixfred).**
> The idea, the pacing and guidance rules, the transcript parsing rules and the
> visual design all come from Burn Bar. Ember re-implements them as a native
> Swift menu-bar app for the Mac. It is an independent port and is not
> affiliated with or endorsed by the original author. MIT licensed, like the
> original.

A live thermal strip in the macOS menu bar for anyone paying for more than one
AI subscription. It reads what **this Mac actually uses** (Claude Code and
Codex), turns it into one heat map, and tells you **what to do**: which
subscription has budget in the bank, which one needs a rest and until when, and
which one to reach for next.

![Ember in the menu bar](docs/img/menubar.png)

## The strip

```
CLAUDE ◄── time ──┤ now ├── time ──► CODEX   CHIP
```

![The strip, enlarged](docs/img/strip.png)

Claude burns on the left and Codex on the right. The newest bucket of each
sits against the centre divider, so the divider is always "now" and time
radiates outward. Colour carries the token count on a ramp from cold ember
through the agent's colour and amber to white-hot. Height is only a secondary
swell. The thin line under each lane is its plan gauge, which turns amber when
the plan is over pace and red when it is spent.

The chip beside the cells gives guidance, not multipliers. While a sub is past
an even spend it says what to do (`CLAUDE REST 8H`, `CODEX SPENT`,
`CLAUDE 5H OUT IN 40M`). With nothing to warn about it names the sub to use
next, in that sub's colour.

## The cockpit

Click the strip. A guidance banner (`USE CODEX NEXT`, `KEEP USING CLAUDE`,
`USE CODEX NOW: use it or lose it`) sits above one card per subscription:

- **Verdict**: ON TRACK, AT PACE, OVER or WAY OVER. Over starts 5% past an
  even spend.
- **What to do**: `BANKED 49%` with a running clock of time in the bank,
  `COME BACK IN 8:36:42` if you stop, `BACK AT THE RESET`, or `ON PACE`.
- **Headline**: budget (share of the plan spent) or tokens. Click it to flip.
- **Burndown**: an even-spend diagonal, the measured line and a projection.
- **Instruction**: how much you can spend per hour and still make the reset,
  and when the plan runs dry at the current rate.
- **Windows**: every limit the provider reports, with a gauge, an even-spend
  tick and the reset. A window whose reset has passed reads "rolled over" and
  its figure is withheld.
- **Burn, token mix, by model.**

SETUP (top right of the panel) holds every option: lanes, strip window and
cell count, refresh rates, card headline, glow reason, 5-hour session windows
and launch at login. `R` refreshes.

## The rules it keeps

These are Burn Bar's rules, ported unchanged and covered by tests:

- **It needs a choice.** It suggests nothing unless there are two
  subscriptions.
- **Only a sub that is ahead is ever suggested.** The winner has the most plan
  left against the clock it has left, which compares a week and a month on the
  same scale.
- **A full 5-hour window blocks a sub**, and so does one that will be full
  within half an hour.
- **A snapshot is not treated as exact.** Codex only reports its quota when
  Codex runs, so an older reading needs five times the margin and says when it
  was measured (`BANKED ~44% · as of Thu 11:55 AM`).
- **It does not flap.** The current pick keeps the job until another sub is
  clearly better.
- **A lane you untick is left out**: no cells, no card, no advice.

## Install

You need macOS 14 or later and the Xcode Command Line Tools
(`xcode-select --install`). Full Xcode is not required.

```sh
./scripts/bundle.sh          # builds dist/Ember.app
open dist/Ember.app
```

Move `dist/Ember.app` to `/Applications` and tick **Launch at login** in SETUP
to keep it running. While developing, use `swift run Ember`.

Two diagnostic modes:

```sh
swift run Ember --print            # one collector run, a text summary, exit
swift run Ember --render out/      # writes strip.png and cockpit-*.png
```

Tests run without Xcode, because the Command Line Tools ship neither XCTest nor
the swift-testing macros:

```sh
swift run ember-checks
```

## Where the numbers come from

- **Claude**: `~/.claude/projects/**/*.jsonl`. Assistant lines carry
  `message.usage`. The same message is re-serialized as it streams, so
  `message.id` is the dedupe key and the largest revision counts. The heat map
  counts fresh input, cache writes and output. Cache reads are carried
  separately for the token mix.
- **Codex**: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. The `token_count`
  events carry a cumulative counter, and Ember counts the deltas. The same
  events carry `rate_limits` (the 5-hour and weekly windows, and the plan),
  which is Codex's plan meter.
- **Claude limits**: Claude Code writes no quota into its transcripts, so Ember
  asks the endpoint that Claude Code's own `/usage` uses
  (`api.anthropic.com/api/oauth/usage`). It uses the sign-in that Claude Code
  already keeps in the login keychain, read through `/usr/bin/security`.
  The endpoint is undocumented and may change. Every field is read defensively,
  and anything that does not parse is withheld rather than shown as 0%. You can
  turn this off in SETUP. Ember then shows Claude in tokens only.

Scanning is incremental. An unchanged file replays its cached contribution. A
file that grew is read from the previous offset, but only if the 48 bytes
before that offset still match. Ember's state lives in
`~/Library/Application Support/Ember/`: the scan cache and the history of
measured percentages that the burndown is drawn from.

## Privacy

Ember reads your Claude and Codex transcripts on this Mac to count tokens. It
keeps numbers, model names and message ids, never message text. The only
network request it makes is the Claude limits probe described above. That
request goes only to `api.anthropic.com`, using the token Claude Code already
holds. The token is never stored, logged or refreshed, because refreshing it
would rotate Claude Code's own sign-in.

## Differences from Burn Bar

Ember covers part of Burn Bar so far:

- Lanes for Claude and Codex only. Grok, Kimi, Zcode and the local
  Ollama/GPU lane are not ported yet.
- No ember flicker, impact shockwave or sparks yet. The strip redraws on
  every refresh but does not animate.
- The burndown line is drawn from percentages Ember itself has measured, so it
  fills in over time after install.

## Credits

[Burn Bar](https://github.com/nixfred/burnbar) by nixfred, the Omarchy plugin
this is a port of. Go and star it.

## License

MIT. See [LICENSE](LICENSE), which carries both the Ember copyright and the
original Burn Bar copyright.
