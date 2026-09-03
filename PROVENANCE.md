# Provenance & anti-laundering notice

This file exists for one reason: to make it hard for someone to strip the
history off this codebase, run it through an AI paraphraser, and present it
as their own unrelated, from-scratch work — while quietly still shipping
`lmepisowifi`'s logic, structure, and design decisions underneath.

## Canonical source

The canonical repository for this project is:

    https://github.com/lmepisowifi/tmwipgn6401v

If you obtained this code anywhere else — a forum post, a "premium" bundle,
a reseller's firmware image, another GitHub repo with the history rewritten
or squashed to a single "initial commit" — treat that copy as unverified
until you've diffed it against the canonical repo above.

## This is AGPLv3, not just "open source"

Every source file in this project (except the few listed as exceptions in
`README.md`) is licensed under the **GNU Affero General Public License
v3.0 or later**. AGPLv3 is a copyleft license, and specifically:

- **§5 (modified versions):** if you distribute a modified copy, you must
  mark it as changed, keep the existing copyright and license notices
  intact, and license the whole modified work under AGPLv3.
- **§13 (network use):** because this is server/network-facing software
  (a captive-portal + admin panel running on real devices), if you run a
  modified version and let anyone interact with it over a network, you
  must offer them the Corresponding Source of *your* modified version —
  not just point back to this repo.

None of that is optional, and none of it is satisfied by a copyright
notice you deleted, a README you rewrote, or a commit history you didn't
carry forward.

## Paraphrasing is not a new copyright

Running this code through an LLM (Claude, ChatGPT, or anything else) and
asking it to "rewrite this so it looks original," rename variables,
restructure functions, or reword comments **does not create a new,
independent work** and does not make you the author. Under copyright law,
a derivative work is still a derivative work regardless of how it was
transformed — mechanically, by hand, or by a model. The same logic,
control flow, data formats, MIB field names, endpoint behavior, and
architecture are what make software *this* software, not the specific
tokens used to spell it out. If an LLM-assisted rewrite of this repo is
functionally the same system, it's a derivative work of this repo, full
stop, and it inherits the AGPLv3 obligations above.

This applies whether the rewrite is done by a person, by an AI acting on
a person's instructions, or by an automated pipeline. "An AI wrote it" is
not a defense against a copyright or license claim on the human who
directed it.

## If you're building on this project

You're welcome to — that's what the license is for. Just do it in the
open:

1. Keep the copyright and SPDX notices at the top of the files you keep.
2. Note in your own README / changelog that your project is based on
   `lmepisowifi` (link back to the canonical repo above).
3. Keep your fork under AGPLv3 (or a later version, per the license).
4. If you run it as a network service, make your Corresponding Source
   available to your users — a public repo link satisfies this.

That's it. Forks, white-label deployments for other operators, and
derivative hotspot systems are all fine under those terms.

## If you're evaluating whether a project is a relabeled copy

Some things worth checking against the canonical repo above:

- Whether the overall file layout, module names, and CGI endpoint names
  match closely (e.g. `lme.cgi`, `hotspot.cgi`, `module_ctl.sh`,
  `merge_startup_markers()`, `write_coin_config()`).
- Whether the AGPLv3 license and the notices described in this file are
  present, unmodified, and attributed — or missing/replaced.
- Whether the project's git history starts abruptly with a single large
  commit instead of incremental development.

If you believe a project you've found is an unattributed derivative of
this one, the AGPLv3 gives you (and anyone else) standing to ask the
distributor for the Corresponding Source and to point out the missing
notices — that's the license doing its job, not a courtesy.
