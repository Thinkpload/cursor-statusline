# Cursor CLI status line

Custom status line for the Cursor agent CLI: context gauge, plan usage, local PC power (PWR), and Composer GPU estimate (SRV).

## Install

```bash
./install.sh
```

Add the `statusLine` block from `cli-config.statusline.json` to `~/.cursor/cli-config.json`, then restart the CLI.

## Layout

```
[Composer 2.5 Fast] project | branch
CTX  ████░░░░░░░░░░ 34%  15k in · 1.2k out · 200k cap
PLAN ███░░░░░░░░░░░ 22%  total $42 · incl $20/$20 · bonus $22
PWR  ⚡ 844 mWh session  ████████░░░░░░ 58%  38W now  local PC
SRV  ☁ ~1.3 Wh session   ██████████████ 100%  280W now  Composer 2.5 Fast · GPU
```

## Tune

| File | Purpose |
|------|---------|
| `statusline-power.conf` | Local PC TDP, idle watts, electricity rate |
| `statusline-cloud.conf` | Composer GPU Wh/token rates and GPU idle/max |

## Notes

- PLAN reads Cursor billing via local auth (`~/.config/cursor/auth.json`).
- PWR tracks local `cursor-agent` CPU usage per session.
- SRV estimates cloud GPU energy from session tokens (not official Cursor metrics).
