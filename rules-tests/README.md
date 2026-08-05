# Firestore rules tests

Real assertions against `firestore.rules`, run through Firebase's own rules test engine
(`firebaserules.googleapis.com/v1/projects/kulan-2ef85:test`). **Nothing is deployed and nothing is
written.** The engine evaluates the rules source you hand it against a request you describe.

```
cd rules-tests
node private-state.test.js              # against ../firestore.rules
node private-state.test.js old.rules    # or any other rules file
```

Auth comes from the firebase-tools login already on this machine (`auth.js` reads the CLI's stored
refresh token). The client id/secret in there are firebase-tools' own public ones, shipped in the
open-source CLI; the actual credential is the refresh token on disk, which is not in this repo.

## Two traps, both of which produce confident wrong answers

**1. `resource.data` takes PLAIN JSON, not Firestore typed values.**

```js
resource: { data: { users: ['uidA', 'uidB'] } }                              // right
resource: { data: { users: { arrayValue: { values: [...] } } } }             // wrong
```

Typed values do not error. They parse, and then every rule that reads a *value* quietly evaluates
false, so the document denies everything — and a suite made of DENY assertions passes completely,
for entirely the wrong reason. This cost a session: `2062fe3` shipped saying "NOT PROVEN BY TEST"
because a plain read of a conversation returned FAILURE with no diagnostic, and that was why.

Note `user-fields.test.js` uses typed values and is still correct, which is what makes this
confusing. Those rules only ever test KEY sets (`keys()`, `diff().affectedKeys()`), and the key
names are identical under both encodings. The moment a rule reads a value, the encoding matters.

**2. Cross-document `get()` / `exists()` must be mocked.**

The conversation rules call `get(users/$(uid))` (the ban check) and `get(conversations/$(cid))`.
An unmocked call does not return null, it errors, and the error fails the whole expression. Supply
`functionMocks` for every path the rules can reach. `functionCalls: []` in the response means
nothing was evaluated at all.

## Always run the control

A passing DENY suite proves nothing on its own — a rule that denies everything passes it. Every
test file here is written so it can be pointed at the PRE-FIX rules, and the fix is only proven
when the attacks flip:

```
git show <fix-commit>^:firestore.rules > old.rules
node private-state.test.js old.rules     # attacks must be ALLOWED here
node private-state.test.js               # and DENIED here
```

Both runs must keep the ALLOW cases passing. That is what shows the fix is aimed at the hole and
not just at the feature.
