# Migrating an existing fork to restic backups

Forks created before the restic backup carry nightly git-crypt'd dumps
under `hindsight-data/`, `hermes-data/`, `parley-data/` (older ones
`sidekick-data/`). Every night added the whole dump to history; a fork
that has run for months is tens of GB and will eventually hit GitHub's
repository size quota, which then refuses every push. Do this once:

1. **Stop the old crons** on the active host (`crontab -e`): remove the
   `sync-hermes-state.sh`, `sync-hindsight-bank.sh` and `sync-parley-db.sh`
   lines. (Keep `sync-hermes.sh`, `sync-cc-history.sh`, `doctor.sh`.)
2. **Pull this template version** into your fork (`scripts/update-workflow.sh`
   or a merge), then `git rm -r --cached hindsight-data hermes-data parley-data sidekick-data`
   and delete the directories. They are `.gitignore`d from now on.
3. **Run bootstrap** (`scripts/bootstrap.sh`, or `--unattended`): installs
   restic + rclone, generates `backups/restic.key`, installs the 03:33
   `backup-nightly.sh` cron. Set `BACKUP_CLOUD_REPO` when prompted (or in
   `~/.hermes/.env`) if you want an off-host copy; for Google Drive fill in
   `backups/rclone.conf` from `backups/rclone.conf.example`.
4. **First backup + check**: `scripts/backup-nightly.sh --no-cloud --check`,
   then `scripts/backup-nightly.sh` once the cloud repo is configured.
5. **Prove the restore**: `scripts/restore-test.sh` must print `RESULT: PASS`.
6. **Commit** the key and config (`git add backups .gitattributes .gitignore && git commit`).
   Verify the key is encrypted in git: `git show HEAD:backups/restic.key | head -c 9`
   must start with `GITCRYPT`.

## Shrinking the history

Only needed if the fork already carries dumps. Git never releases the
space on its own, and GitHub keeps old objects after a force push and
refuses pushes while over quota, so the clean route is a new repository:

```
tar -cf ~/git-before-rewrite.tar -C <fork> .git           # keep until the new repo is verified
git clone --no-hardlinks <fork> ~/rewrite && cd ~/rewrite
git filter-repo --force --invert-paths \
    --path hindsight-data/ --path hermes-data/ --path parley-data/ --path sidekick-data/
git reflog expire --expire=now --all && git gc --prune=now --aggressive
du -sh .git                                                 # a few GB at most
```

Then on GitHub: rename the old repository (Settings → General →
Repository name, e.g. `<name>-old`), create a new empty private repository
under the original name, and move the deploy key to it (Settings → Deploy
keys; delete on the old, add the same public key on the new, write access).
Push and replace the clones:

```
cd ~/rewrite && git remote add origin git@github.com:<you>/<name>.git && git push -u origin main
mv <fork> <fork>.old && git clone git@github.com:<you>/<name>.git <fork>
cd <fork> && git-crypt unlock <exported-key>                # git-crypt export-key from the old clone
```

Repeat the clone + unlock on every other host. Delete `<fork>.old`, the
old GitHub repository and the tarball once `scripts/restore-test.sh`
passes against the restic repo and the nightly run has succeeded.

Optional: keep a coarse past by seeding the restic repo with a few
historical snapshots before deleting the old clone — check out the dump
dirs at one commit per month (`git worktree add --detach <dir> <sha>`; for
git-crypt in a worktree link `../../git-crypt` into
`.git/worktrees/<name>/`) and `restic backup <dirs> --tag seed --time "<date>"`.
