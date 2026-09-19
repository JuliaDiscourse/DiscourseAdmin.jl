# DiscourseAdmin.jl: Discourse Config as Code

Discourse has a very simple admin API with each route describing a group of settings, and it's possible to ask for only the _overridden_ ones. This repository stores, syncs, and enables collaboration for these overrides on the [Julia Discourse board](https://discourse.julialang.org).

## Currently supported endpoints

### Site Texts

The [Site Texts feature of Discourse](https://meta.discourse.org/t/customize-text-in-discourse/36092) allows overriding (and optionally translating) pretty much every and any text that appears on the platform. These can range from very short slugs (like date formats) to long form (and crucially critical) community resources like the site guidelines. One special thing about site texts is that they are localized and may have multiple values at a single key.

### Custom Flags

The [custom flags feature of Discourse](https://meta.discourse.org/t/custom-flags/312964) allows adding your own reasons for flagging a post or topic, alongside the built-in ones (off-topic, inappropriate, spam, and so on). Unlike the other settings, a flag is a record rather than a single string, so its file holds a JSON object of exactly the fields the admin UI lets you set: `name`, `description`, `applies_to`, `require_message`, `enabled`, and `auto_action_type`. Discourse addresses a flag by the integer id it assigns at creation, and the file is named by that id (`admin/config/flags/1001.json`). To create a flag, add a file with any other name; the pull following the push re-files it under its new id. Only custom flags are mirrored: the built-in flags can't be created, edited, or deleted through this API. A custom flag that has been used can be edited but can no longer be deleted.

### Posts

Some of the most prominent pages of a Discourse site are themselves posts, like the FAQ/Guidelines that lives in a hidden staff category. The `t/` tree holds the bodies of such posts at the paths of their URLs: [`t/faq-guidelines/5.md`](t/faq-guidelines/5.md) is the first post of the topic at [`/t/faq-guidelines/5`](https://discourse.julialang.org/t/faq-guidelines/5), and a `t/faq-guidelines/5/3.md` would be the third post in it. As in the URL, only the numbers matter; the slug is decorative.

Unlike the admin settings, where Discourse lists what is configured, it's the files themselves that declare which posts are mirrored. To start mirroring a post, add an (empty) file for it; the pull following the push fills it with the post's current body, and only later changes to the file edit the post. Deleting a file just stops mirroring the post. Posts are never created or deleted, and only a post's body is managed, not its topic's title or category. Each edit is a regular post revision by the API user, with the commit's URL as its edit reason.

## How it works

The repository's `admin/` tree mirrors the API routes of the same paths, so supporting another key/value endpoint is a matter of making the directory and a `.gitkeep`. The currently-overriden settings at that endpoint will be populated upon merge to main.

An entry on a locale-less route is simply `admin/route/key.ext`. For a localized route (just `site_texts`) it's `route/key/locale.ext`; `admin/customize/site_texts/guidelines_topic.body/en.md` holds the `en` translation of that key.

Extensions are only for display on GitHub; the contents of the file are sent to Discourse verbatim as the entry's value. For the key/value routes that is plaintext; for custom flags it is the JSON record described above.

### Pull from Discourse

The **Pull from Discourse** action mirrors the overrides for every configured route under `admin/` and every post under `t/` from the Discourse API. It runs on a daily schedule, on demand via manual dispatch, and automatically after every push run (see below). This captures changes made through the admin UI.

### Push to Discourse

The **Push to Discourse** action runs upon commit to `main`. It diffs the pushed range of commits and applies each changed file to the entry its path names (see above), with a deleted file reverting that entry to the Discourse default. Commits made by the above pull action are skipped, since that state already came from Discourse.

Before applying anything, the action verifies that the *pre-merge* state of the repository exactly mirrors the live Discourse state. If an admin has changed something through the UI that hasn't been pulled yet, the action fails.

After every push run on `main` — whether it succeeded or failed — the pull action runs and mirrors the live state back into the repo. The pull following a successful push should be a no-op; a failed or partially-applied one is automatically corrected to the current state by the pull commit, so `main` always converges to the live Discourse state with no manual reverts. The failing change can then be rebased and re-landed.

Pull requests run no part of the push action — the API key only ever runs alongside `main`'s own reviewed code, and a PR's diff *is* the preview of the API calls it will make. All PRs must be carefully reviewed, especially with respect to the values they will expose.

In the future, this should explicitly add guardrails to avoid accidentally pulling confidential settings like API keys into the public repository.
