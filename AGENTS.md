# Repository instructions

## Git

Commit and push repository changes at the end of every turn. Push to both
configured remotes, `origin` and `github`. Do not create empty commits when
there are no changes. Run the repository's pre-publish scan before pushing.

## macOS deployment

“Redeploy” means build the latest macOS app (reusing a current build when
possible) and install it to `~/Applications/fb.app`. Use
`macos/Scripts/deploy.sh`. It does not mean publish a release or restart the
web server service.

The legacy HTTP server is deprecated. Do not start or reinstall its LaunchAgent
or Homebrew service as part of app development, deployment, or release work.
The standalone app needs no listening backend.

## Email

For any email work (sending, drafting, replying, notifying Mike), use
`butler email`. Before first use in a session, run `butler email help` and
follow it.
