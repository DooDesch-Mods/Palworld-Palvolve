# The Egg Filter

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

Palvolve lets you evolve a captured Pal into a related form. The egg filter is the breeding side of that: with it on, eggs only ever hatch **base forms**, so an evolved Pal stays something you earned at the workbench instead of something that falls out of an egg. It changes nothing about how eggs are made, only what comes out of them.

The filter is **off by default** (opt-in). Turn it on and eggs of evolved forms hatch their base species; leave it off and breeding behaves exactly like vanilla Palworld. This guide explains what it does when it is on, so you can decide whether you want it.

## Turning it on and off

Two ways, they do the same thing:

- **Web configurator** - open [palvolve.doodesch.de](https://palvolve.doodesch.de), enable the egg filter in the settings, and export your `config_user.lua` into `%LocalAppData%\Pal\Saved\Palvolve\`.
- **By hand** - in `scripts\config.lua`, set `eggFilter = { enabled = true }`.

On a co-op or dedicated setup the host or server owns the decision, so the filter setting there is the one that counts.

## What an egg hatches

Every pair Palvolve knows is one of three kinds, and the filter treats them differently:

- **Evolution** (Pengullet to Penking) - a Pal becoming a different Pal. This is the only kind the filter walks backwards.
- **Adaptation** (Pengullet to Pengullet Lux) - a Pal changing its element. Never gated. An egg of a pure element variant hatches unchanged.
- **Fun chain** (Cattiva to Nyafia) - a deliberate joke transformation. Never walked. A fun-chain result hatches unchanged, so a Nyafia egg stays a Nyafia egg.

So when an egg finishes incubating, the decision looks like this:

```mermaid
flowchart TD
    A(["An egg finishes incubating.<br/>Its stored species is X."]) --> B{"Egg filter on?"}
    B -->|No| Z1["Hatches X.<br/>Vanilla behavior."]
    B -->|Yes| C{"Is X an evolved form<br/>(does it sit above a base<br/>on an evolution chain)?"}
    C -->|"No: X is a base form,<br/>an element variant,<br/>or a fun-chain result"| Z2["Hatches X unchanged."]
    C -->|"Yes"| D["Collect X's candidates:<br/>the base it evolves from,<br/>plus any form that can be<br/>adapted INTO that base."]
    D --> E{"More than one<br/>candidate?"}
    E -->|"One"| Z3["Hatches that base."]
    E -->|"Several"| Z4["Hatches one of them,<br/>equal chance each."]
```

Adaptation runs one way. Pengullet can be adapted into Pengullet Lux, but a Pengullet Lux cannot be turned back into a Pengullet. That is why the candidates only ever include forms you could still adapt into the base you were owed: handing you a variant instead would leave you stuck with the wrong Pal.

The candidate set is the part that decides the outcome, so here is a real one.

## A worked example: the Pengullet family

Three of the pairs Palvolve ships for the Pengullet family:

```mermaid
flowchart LR
    P["Pengullet"] -->|evolution| PK["Penking"]
    P -->|adaptation| PL["Pengullet Lux"]
    PL -->|evolution| PKL["Penking Lux"]
```

Pengullet has an evolved form (Penking) and an element variant (Pengullet Lux), and that variant has its own evolved form (Penking Lux). The two evolved forms sit above different bases: Penking comes from Pengullet, Penking Lux comes from Pengullet Lux.

Run every egg in the family through the filter and you get:

| Egg of | Filter off | Filter on |
|---|---|---|
| Pengullet | Pengullet | Pengullet - it is already a base |
| Pengullet Lux | Pengullet Lux | Pengullet Lux - element variants are never gated |
| Penking | Penking | Pengullet |
| Penking Lux | Penking Lux | Pengullet Lux **or** Pengullet, equal chance |

A Penking egg always gives you Pengullet. Pengullet Lux is not an option there, because you could never adapt it back into the Pengullet the egg was worth.

A Penking Lux egg is the one with a choice. It is worth a Pengullet Lux, and a plain Pengullet can still be adapted into one, so both are fair outcomes and each has an equal chance.

## The rules in one place

- **Base form** - hatches unchanged.
- **Element variant** (pure adaptation, nothing evolves into it) - hatches unchanged.
- **Evolved form** - hatches the base it came from, or any form that can still be adapted into that base. Sibling variants of the base are never candidates, because adaptation only runs one way. If more than one candidate qualifies, one is chosen at random with an equal chance.
- **Fun-chain result** - hatches unchanged. Fun chains are never walked back.

Two things follow from this:

- The filter reads **your** tree. If you rewire pairs in the configurator, mark a link as an adaptation instead of an evolution, or disable a pair, the egg filter follows those exact pairs. The Pengullet outcome above is only what the shipped tree produces.
- The choice is made while the egg hatches, not when it is laid, so the current setting applies to eggs that are already incubating.

## What it does not touch

- **Which eggs you get:** breeding combinations and egg drops are unchanged. The filter only rewrites the species an egg hatches into, and only for evolved forms.
- **Stats and identity:** a normalized hatch is a normal newborn of the base species. Nothing is copied over from the evolved form, because it was never born as one.
- **Pals you already own:** only eggs are affected. An evolved Pal in your team or Palbox stays exactly as it is.
