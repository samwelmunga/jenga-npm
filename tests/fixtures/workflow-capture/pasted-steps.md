How to cut a release (from the team wiki):

1. Create the branch release/1.4 from main.
2) Bump the version in package.json to 1.4.0
   and commit it with the message "chore: 1.4.0".
3. Export NPM_TOKEN=npm_abcdefghijklmnop1234 and publish the package.

4. Tag the release v1.4.0 and push the tag.
