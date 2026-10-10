# CooldownCue

A World of Warcraft addon for **Midnight (12.x)**. When you press an ability that is
still on cooldown, it briefly flashes the ability's icon with the remaining cooldown
in the middle, styled like Blizzard's Cooldown Manager. It works in combat.

Abilities with a short cooldown are ignored (default: 15 seconds or less), so the
popup only appears for the long cooldowns you actually want to be reminded about.

<img width="400" height="312" alt="gif" src="https://github.com/user-attachments/assets/92b649ea-a48a-419a-8c90-d072a203b49e" />

## Install

Copy the `CooldownCue` folder into `World of Warcraft/_retail_/Interface/AddOns/`
(or clone this repository there), then restart the game or `/reload`.

Requires a Midnight client at **12.0.5 or newer**.

## Commands

`/cdc` or `/cooldowncue`

| Command | Description |
|---|---|
| `size <16-256>` | Icon size in pixels (default 64) |
| `font <8-120>` | Countdown number size (default 24) |
| `seconds` | Toggle seconds-only countdown (`75` instead of `1:15`), default on |
| `min <seconds>` | Only show abilities whose cooldown is longer than this (default 15) |
| `time <seconds>` | How long the popup stays up (default 1) |
| `pos <x> <y>` | Offset from the screen centre (default `0 -80`) |
| `unlock` / `lock` | Drag the popup to a new position with the mouse |
| `test` | Show a sample popup |
| `reset` | Restore the defaults |
| `cache` | List the ability cooldowns the addon has cached |
| `debug` | Print why each button press was shown or ignored |
| `probe` | Print every source the addon can find for an ability's cooldown |

Settings are saved per account in `CooldownCueDB`.

## How it works

Since Midnight, cooldown values are "secret" in combat: addons cannot read or compare
them. CooldownCue therefore never reads them:

- It decides whether to show the popup using the `isActive` / `isOnGCD` flags, which
  are never secret.
- It hands the action's duration object to a `Cooldown` widget, which draws the
  countdown itself.
- To apply the minimum-cooldown filter it reads the ability's cooldown from its tooltip
  ("1.3 min cooldown", "8.9 sec recharge") while out of combat and caches it per ability.
  `GetSpellBaseCooldown` is not used because it returns wrong values for talent and
  charge-based cooldowns.

## License

[MIT](LICENSE)
