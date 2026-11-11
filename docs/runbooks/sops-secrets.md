# Deploy secrets with SOPS (r36)

The deploy's secrets can live encrypted in the repository, in `secrets/deploy.sops.yaml` (SOPS with an age key). GitHub then
needs one secret, `SOPS_AGE_KEY`, instead of one per value. Only the values are encrypted; the names stay readable, so a
change shows in review. A decrypted copy is never committed (`.gitignore` refuses everything in `secrets/` except
`*.sops.yaml`).

How the deploy reads it: the first step of the deploy job (`.github/actions/sops-env`) downloads sops (pinned version,
checked against its checksum), decrypts the file with `SOPS_AGE_KEY`, masks every value in the log and makes each one
available to every later step. A value only fills a variable that is empty: while a GitHub secret of the same name is
still set, it wins. Without `SOPS_AGE_KEY` or without the file, nothing changes.

## Moving over (once, on your computer)

1. Install the tools: `brew install sops age` (and `gh`, signed in, so step 4 is done for you).
2. Make a plain file outside the repository, one `NAME: value` a line, with the secrets the deploy job uses today
   (`.github/workflows/ci.yml`, deploy job `env:`), for example:

   ```yaml
   SUPABASE_ACCESS_TOKEN: ...
   SUPABASE_PROJECT_REF: ...
   SUPABASE_DB_PASSWORD: ...
   CLOUDFLARE_API_TOKEN: ...
   CLOUDFLARE_ACCOUNT_ID: ...
   QUO_API_KEY: ...
   GEMINI_API_KEY: ...
   TWILIO_ACCOUNT_SID: ...
   TWILIO_API_KEY: ...
   TWILIO_API_SECRET: ...
   TWILIO_CALLER_ID: ...
   TWILIO_AUTH_TOKEN: ...
   VPS_SSH_KEY: |
     -----BEGIN OPENSSH PRIVATE KEY-----
     ...
   ```

3. Run `scripts/secrets/sops-init.sh ~/deploy-secrets.yaml`. It makes your age key (once, in
   `~/.config/sops/age/keys.txt`: keep a copy in your password manager), writes its public key into `.sops.yaml`,
   encrypts the file into `secrets/deploy.sops.yaml` and deletes the plain file.
4. It sets the repository secret `SOPS_AGE_KEY` with `gh`. Without `gh`, paste the line starting `AGE-SECRET-KEY-` from
   the keys file into GitHub > Settings > Secrets and variables > Actions > New repository secret, named `SOPS_AGE_KEY`.
5. Commit `.sops.yaml` and `secrets/deploy.sops.yaml`, and deploy. The deploy's first step says how many values came from
   the file.
6. Once a deploy has passed, delete the old GitHub secrets one by one (Settings > Secrets). Each deleted secret is then read
   from the file. Keep `SOPS_AGE_KEY`. The values the deploy reads from the Supabase vault are unchanged.

## Changing a value

`sops secrets/deploy.sops.yaml` opens it decrypted in your editor and encrypts it again on save. Or run
`scripts/secrets/sops-init.sh <file>` with only the changed lines: they are merged in. Commit and deploy.

## A new key (someone left, the key leaked)

1. `age-keygen -o new.txt`; put the new public key in `.sops.yaml` (replace the old one).
2. `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys secrets/deploy.sops.yaml` (re-encrypts for the new key).
3. Set `SOPS_AGE_KEY` to the new private key, move `new.txt` to `~/.config/sops/age/keys.txt`, commit and deploy.
4. Change the secrets themselves at their services if the old key may have been seen.

## Other workflows

Only the deploy job reads the file today. Another workflow can use it with the same step:

```yaml
- uses: ./.github/actions/sops-env
  with:
    age-key: ${{ secrets.SOPS_AGE_KEY }}
```
