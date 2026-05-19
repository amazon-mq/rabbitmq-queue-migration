# `amazon-mq/rabbitmq-queue-migration` release process

Here are the commands to run when releasing a new version of this project:

```
readonly VER=0.2.0
git checkout -b "rabbitmq-queue-migration-$VER"
sed -i.bak "s/^PROJECT_VERSION =.*/PROJECT_VERSION = $VER/" Makefile
github_changelog_generator --future-release "$VER" --user amazon-mq --project rabbitmq-queue-migration --token "$GITHUB_API_TOKEN"

# Optional - remove last line of CHANGELOG.md

git add CHANGELOG.md
git commit -a -m "rabbitmq-queue-migration $VER"
git push -u origin "rabbitmq-queue-migration-$VER"
gh pr create --fill
```

* Ensure CI runs successfully for the PR
* Merge PR

```
git checkout main
git pull origin main
git remote prune origin
git branch -d "rabbitmq-queue-migration-$VER"
git tag --annotate --sign --local-user="$GPG_KEY_ID" --message="rabbitmq-queue-migration $VER" "$VER"
git push --tags
```

* Ensure that Erlang/OTP 26.x and Elixir 1.16.x are in your `PATH`

```
git clone --branch v4.2.x https://github.com/rabbitmq/rabbitmq-server.git rabbitmq-server_4.2.x
cd rabbitmq-server_4.2.x
git clone --branch "$VER" https://github.com/amazon-mq/rabbitmq-queue-migration.git deps/rabbitmq_queue_migration
make
make -C deps/rabbitmq_queue_migration
make -C deps/rabbitmq_queue_migration DIST_AS_EZS=true dist
cd deps/rabbitmq_queue_migration
gh release create "$VER" --verify-tag --title "rabbitmq-queue-migration $VER" --latest --generate-notes "./plugins/rabbitmq-queue-migration-$VER.ez"
```

* (Optional) Update generated release on GitHub to add GitHub milestone
