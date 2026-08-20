# ⛔ THIS FOLDER IS NOT THE WEBSITE

`fariin.com` is NOT served from here. It is deployed from the other repo, and what is live there
is a Fariin-branded holding page plus the real `/privacy`, `/terms` and `/support` pages.

What sits in this folder is an OLD copy that still calls the app **Kulan**, still lists
`kulanchat@gmail.com` as support, and predates the rename. It is kept only because the
universal-link fallback pages and the `apple-app-site-association` file were authored here.

## What was about to go wrong

`firebase.json` in this repo used to declare `hosting: { "public": "web" }`. Anybody running

    firebase deploy                      # or --only hosting

from Kulan-iOS would have replaced the live Fariin site with these stale Kulan pages — including
the Privacy Policy and Terms URLs that App Store Connect requires to resolve, and that the app
links to from Settings. The hosting block is removed from `firebase.json` for exactly that reason.
This repo can now only deploy **storage** and **firestore** rules, which is all it owns.

⚠️ Do not add a hosting block back here. If the site needs changing, change it where it is
deployed from.
