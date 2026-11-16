# Contributing to Oscillux

Oscillux is pre-1.0. Contributions are welcome where they fit the invariants in
[AGENTS.md](AGENTS.md).

## Building and testing

```sh
make gate
```

`make gate` is the merge gate: formatting, lints with warnings denied, and the test suite. Numeric
behaviour is specified by the vectors under `conformance/`; a change that alters an output updates
its vectors in the same change and says why.

## Change hygiene

- One concern per change.
- Every source file starts with `SPDX-License-Identifier: AGPL-3.0-only` (see
  [LICENSING.md](LICENSING.md)).
- Keep the library free of product-specific names, catalogs and policy; hosts supply those.

## Licensing

Oscillux is free software under the GNU AGPL v3 (`AGPL-3.0-only`, [LICENSING.md](LICENSING.md)).
Contributions to the public repository are licensed under it.

The owner also licenses Oscillux under separate terms. Outside contributions require an explicit acceptance of the
[contributor agreement](CONTRIBUTOR-AGREEMENT.md), or a separately recorded sufficient rights grant,
before merge. Contributors retain ownership. This additional permission includes proprietary
commercial sublicensing; submission under the public licence or a DCO signoff alone is insufficient.

Use the authenticated pull-request acceptance statement in the agreement, identify its immutable
text revision and covered contribution commits, and obtain acknowledgment from the owner or an
expressly authorized maintainer. Each rights holder must grant the necessary permissions; include
the represented organization and authority where an employer or client owns the work. Public
acceptance is manual and requires no paid signing service or outside legal review.

Maintainers retain the agreement text, accepted contribution bytes, authenticated acceptance and
acknowledgment, and any authority evidence in private rights records before merging. Later commits
need coverage. For squashed or rewritten commits, record the accepted-to-merged mapping, verify
preserved content, and resolve rights to any additional or conflict-resolution material. Missing
or uncertain grants keep the affected contribution on hold. Do not place sensitive identity or
employment documents in Git or public comments; the agreement describes a private alternative.

Issue reports and discussion are welcome without agreement acceptance. All contributions must disclose third-party material
and preserve its applicable terms and notices. Previously merged work is not retroactively covered;
obtain any additional permission needed before including it under alternative commercial terms.
