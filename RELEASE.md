# `amazon-mq/rabbitmq-queue-migration` release process

Releases are driven by `release.sh`, which splits the process into four
subcommands around the manual "merge the PR" gate. Run each phase in order.

`release.sh` must be run from within a rabbitmq-server 3.13.x clone, checked
out as `deps/rabbitmq_queue_migration`. That layout is what lets the `build`
phase produce the `.ez` archive without a separate server clone.

## Prerequisites

* Erlang/OTP 26.x and Elixir 1.16.x in your `PATH`
* `GITHUB_API_TOKEN` set (used by `prepare` and `publish`)
* `GPG_KEY_ID` set to your signing key (used by `tag`)
* `gh`, `git`, `make`, `gpg`, `sed`, and `github_changelog_generator` installed

Preview any phase without making changes using `--dry-run`; skip the
confirmation prompts before irreversible steps with `--yes`:

```
./release.sh --dry-run prepare 1.2.1
```

## 1. Prepare the release PR

```
./release.sh prepare 1.2.1
```

This creates the `rabbitmq-queue-migration-1.2.1` branch, bumps
`PROJECT_VERSION` in the `Makefile`, regenerates `CHANGELOG.md` (user,
project, header, and excluded labels come from `.github_changelog_generator`;
the trailing credit line is stripped automatically), commits, pushes, and
opens a PR.

* Ensure CI runs successfully for the PR
* Merge the PR

## 2. Tag the release

```
./release.sh tag 1.2.1
```

Updates `main`, deletes the merged release branch, and creates and pushes the
GPG-signed annotated tag.

## 3. Build the plugin archive

```
./release.sh build 1.2.1
```

Runs `make DIST_AS_EZS=true dist` and verifies the archive at
`plugins/rabbitmq_queue_migration-1.2.1.ez`. The build must run with the tag
checked out; otherwise the archive is named with a `+dirty`/commit suffix and
the version will not match.

## 4. Publish the GitHub release

```
./release.sh publish 1.2.1
```

Creates the GitHub release from the tag, marks it `--latest`, and uploads the
`.ez` archive.

* (Optional) Update the generated release on GitHub to add the GitHub milestone
